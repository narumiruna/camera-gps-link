import Combine
import CoreBluetooth
import CoreLocation
import Foundation
import OSLog

final class CameraBLEManager: NSObject, ObservableObject {
    @Published var state: CameraConnectionState = .idle
    @Published var discoveredCameraName: String?
    @Published var lastSentAt: Date?
    @Published var packetsSent = 0
    @Published var includeTimezone = true
    @Published var dd21ConfigHex: String?
    @Published var detectedFirmware: String?
    @Published var advertisementProtocolVersion: Int?
    @Published var resolvedProfile: SonyLocationProfile?
    @Published var supportConfidence: SonySupportConfidence = .experimental
    @Published var packetSize: Int?
    @Published var experimentalApprovalPending = false
    @Published var pairingConfirmationPending = false
    @Published var pairingStatus = "Not requested"
    @Published var pairingCameras: [PairingCamera] = []
    @Published var pairingCompleted = false
    var pairingPeripherals: [UUID: CBPeripheral] = [:]
    @Published var cleanupDiagnostic: String?
    @Published var sanitizedOperationOrder: [String] = []
    @Published var lastError: String?
    @Published var backgroundLinkEnabled = UserDefaults.standard.bool(
        forKey: CameraBLEDefaults.backgroundLinkEnabled
    )
    @Published var lowPowerModeEnabled =
        UserDefaults.standard.object(
            forKey: CameraBLEDefaults.lowPowerModeEnabled
        ) as? Bool ?? true
    private(set) var rememberedPeripheralID = UserDefaults.standard.string(
        forKey: CameraBLEDefaults.rememberedPeripheralID
    )
    @Published var pendingReconnectArmed = false

    var targetName = "Sony camera"
    var updateInterval: TimeInterval = CameraBLEDefaults.foregroundUpdateInterval

    var centralManager: CBCentralManager!
    var peripheral: CBPeripheral?
    var characteristics: [String: CBCharacteristic] = [:]
    var descriptors: [SonyGattDescriptor] = []
    var pendingCharacteristicServices: Set<String> = []
    var didCompleteIdentityDiscovery = false
    var currentIdentity: SonyCameraIdentity?
    var rejectedPeripheralIDs: Set<UUID> = []
    var resumeScanAfterCandidateRejection = false
    var releaseAuthorization: SonyReleaseAuthorization?
    var sessionApprovalKey: String?
    var acquisition = SonyLocationAcquisition()
    var connectionIntent: CameraConnectionIntent = .location
    var attemptOrigin: CameraAttemptOrigin = .none
    var activeSessionRequested = false
    var isForeground = true
    var userLinkIntentActive = UserDefaults.standard.bool(forKey: CameraBLEDefaults.activeLinkIntent)
    var cancelAfterCurrentOperation = false
    var compensationErrors: [String] = []
    var compensationInProgress = false
    var didStartLocationSetup = false
    var locationProvider: (() -> CLLocation?)?
    var sendTimer: Timer?
    var operationQueue: [QueuedBLEOperation] = []
    var pendingOperation: PendingBLEOperation?
    var timedOutCallbackDebt: [String: Int] = [:]
    var operationTimeoutTimer: Timer?
    var onQueueEmpty: (() -> Void)?
    var resumeWhenBluetoothPowersOn = false
    var manualStopRequested = false
    var reconnectRetryTimer: Timer?
    var foregroundTimeoutSession: ForegroundConnectionTimeoutSession!
    let operationTimeout: TimeInterval = 12
    let maximumLocationAge = ConnectionHealthPolicy.locationFixMaximumAge
    let maximumFutureLocationSkew = ConnectionHealthPolicy.locationFixMaximumFutureSkew
    let diagnosticsStore: DiagnosticsLogStore
    let identityStore: any SonyValidatedIdentityStoring
    let releasePolicy: SonyReleasePolicy
    let sessionPlanner: any SonyLocationSessionPlanning
    let sessionExecutor: any SonyLocationSessionExecuting
    let logger = Logger(subsystem: "dev.narumi.cameragpslink", category: "BLE")
    let connectOptions: [String: Any] = [
        CBConnectPeripheralOptionNotifyOnConnectionKey: true,
        CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
        CBConnectPeripheralOptionNotifyOnNotificationKey: true,
    ]

    override convenience init() {
        self.init(diagnosticsStore: DiagnosticsLogStore())
    }

    convenience init(
        diagnosticsStore: DiagnosticsLogStore,
        releasePolicy: SonyReleasePolicy = .current
    ) {
        self.init(
            diagnosticsStore: diagnosticsStore,
            timeoutPolicy: ForegroundConnectionTimeoutPolicy(),
            timeoutScheduler: .live,
            releasePolicy: releasePolicy
        )
    }

    init(
        diagnosticsStore: DiagnosticsLogStore,
        timeoutPolicy: ForegroundConnectionTimeoutPolicy,
        timeoutScheduler: ConnectionTimeoutScheduler,
        identityStore: any SonyValidatedIdentityStoring = UserDefaultsSonyValidatedIdentityStore(),
        releasePolicy: SonyReleasePolicy = .current,
        sessionPlanner: any SonyLocationSessionPlanning = DefaultSonyLocationSessionPlanner(),
        sessionExecutor: any SonyLocationSessionExecuting = DefaultSonyLocationSessionExecutor()
    ) {
        self.diagnosticsStore = diagnosticsStore
        self.identityStore = identityStore
        self.releasePolicy = releasePolicy
        self.sessionPlanner = sessionPlanner
        self.sessionExecutor = sessionExecutor
        super.init()
        if !releasePolicy.allowsBackground {
            backgroundLinkEnabled = false
            UserDefaults.standard.set(false, forKey: CameraBLEDefaults.backgroundLinkEnabled)
        }
        foregroundTimeoutSession = ForegroundConnectionTimeoutSession(
            policy: timeoutPolicy,
            scheduler: timeoutScheduler
        ) { [weak self] stage in
            self?.handleConnectionStageTimeout(stage: stage)
        }
        updateInterval =
            lowPowerModeEnabled
            ? CameraBLEDefaults.lowPowerUpdateInterval
            : CameraBLEDefaults.foregroundUpdateInterval
        centralManager = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: CameraBLEDefaults.restorationIdentifier]
        )
    }

    var canStart: Bool {
        guard peripheral == nil,
            !(connectionIntent == .pairing && resumeWhenBluetoothPowersOn),
            !compensationInProgress,
            pendingOperation == nil,
            !cancelAfterCurrentOperation
        else { return false }
        return ![.scanning, .connecting, .discovering, .awaitingApproval, .enablingLocation, .linked, .pairing]
            .contains(state)
    }

    var logLines: [String] {
        diagnosticsStore.lines
    }

    var permitsLocationWrites: Bool {
        isForeground || backgroundLinkEnabled
    }

    func configure(backgroundLinkEnabled: Bool, lowPowerModeEnabled: Bool) {
        let effectiveBackgroundLinkEnabled = backgroundLinkEnabled && releasePolicy.allowsBackground
        let didChange =
            self.backgroundLinkEnabled != effectiveBackgroundLinkEnabled
            || self.lowPowerModeEnabled != lowPowerModeEnabled
        self.backgroundLinkEnabled = effectiveBackgroundLinkEnabled
        self.lowPowerModeEnabled = lowPowerModeEnabled
        updateInterval =
            lowPowerModeEnabled
            ? CameraBLEDefaults.lowPowerUpdateInterval
            : CameraBLEDefaults.foregroundUpdateInterval
        UserDefaults.standard.set(effectiveBackgroundLinkEnabled, forKey: CameraBLEDefaults.backgroundLinkEnabled)
        UserDefaults.standard.set(lowPowerModeEnabled, forKey: CameraBLEDefaults.lowPowerModeEnabled)

        if didChange {
            appendLog(
                "BLE settings: backgroundLink=\(effectiveBackgroundLinkEnabled) lowPower=\(lowPowerModeEnabled) interval=\(Int(updateInterval))s"
            )
        }
        if state == .linked {
            restartSendTimer()
        }
        if !effectiveBackgroundLinkEnabled {
            disarmPendingReconnect()
        }
    }

    func handleScenePhase(isForeground: Bool) {
        self.isForeground = isForeground
        if !isForeground, connectionIntent == .pairing {
            cancelPairingInitialization()
            return
        }
        guard !isForeground, !backgroundLinkEnabled else { return }
        stopTimer()
        guard
            [
                .scanning, .connecting, .discovering, .awaitingApproval, .enablingLocation, .linked, .pairing,
            ].contains(state)
        else { return }
        appendLog("Foreground-only location link stopping because the app entered background")
        stopLink()
    }

    func setLocationProvider(_ locationProvider: @escaping () -> CLLocation?) {
        self.locationProvider = locationProvider
    }

    func startLink(locationProvider: @escaping () -> CLLocation?) {
        guard canStart else {
            appendLog("Ignoring start request until the current operation and cleanup finish")
            return
        }
        setLocationProvider(locationProvider)
        manualStopRequested = false
        prepareForNewSession(resetCounters: true)
        connectionIntent = .location
        attemptOrigin = .foreground
        setUserLinkIntent(active: true)
        activeSessionRequested = true
        foregroundTimeoutSession.begin()
        appendLog("Starting Sony location link")

        guard centralManager.state == .poweredOn else {
            foregroundTimeoutSession.end()
            endLinkIntent()
            state = .bluetoothUnavailable
            appendLog("Bluetooth is not powered on: \(centralManager.state.rawValue)")
            return
        }
        connectToRememberedCameraOrScan()
    }

    func resumeBackgroundLink(locationProvider: @escaping () -> CLLocation?) {
        setLocationProvider(locationProvider)
        guard backgroundLinkEnabled, connectionIntent != .pairing else { return }
        guard userLinkIntentActive else {
            appendLog("Ignoring automatic resume without active link intent")
            return
        }
        guard canStart else { return }
        manualStopRequested = false
        foregroundTimeoutSession.end()
        prepareForNewSession(resetCounters: true)
        connectionIntent = .location
        attemptOrigin = .background
        activeSessionRequested = true
        appendLog("Background link enabled; attempting camera reconnect")
        armBackgroundReconnect(reason: "Background Link resume")
    }

    /// End automatic location/reconnect work without skipping the camera cleanup barrier.
    func endLinkIntent() {
        manualStopRequested = true
        setUserLinkIntent(active: false)
        activeSessionRequested = false
        attemptOrigin = .none
        resumeWhenBluetoothPowersOn = false
        disarmPendingReconnect()
    }

    func cancelCurrentAttempt() {
        appendLog("Cancelling current connection attempt")
        manualStopRequested = true
        setUserLinkIntent(active: false)
        activeSessionRequested = false
        attemptOrigin = .none
        cancelConnectionStageTimeout()
        resumeWhenBluetoothPowersOn = false
        centralManager.stopScan()
        clearPairingCandidates()
        disarmPendingReconnect()
        stopTimer()
        experimentalApprovalPending = false
        pairingConfirmationPending = false
        operationQueue.removeAll()
        onQueueEmpty = nil
        guard pendingOperation == nil else {
            cancelAfterCurrentOperation = true
            return
        }
        beginCompensation(finalState: .stopped, disconnectAfter: true)
    }

    func stopLink() {
        appendLog("Stopping Sony location link")
        manualStopRequested = true
        setUserLinkIntent(active: false)
        activeSessionRequested = false
        attemptOrigin = .none
        cancelConnectionStageTimeout()
        resumeWhenBluetoothPowersOn = false
        centralManager.stopScan()
        disarmPendingReconnect()
        stopTimer()
        state = .stopping
        operationQueue.removeAll()
        onQueueEmpty = nil
        experimentalApprovalPending = false
        pairingConfirmationPending = false
        guard pendingOperation == nil else {
            cancelAfterCurrentOperation = true
            return
        }
        beginCompensation(finalState: .stopped, disconnectAfter: true)
    }

    func prepareForNewSession(resetCounters: Bool) {
        cancelConnectionStageTimeout()
        if resetCounters {
            packetsSent = 0
            lastSentAt = nil
        }
        lastError = nil
        dd21ConfigHex = nil
        detectedFirmware = nil
        advertisementProtocolVersion = nil
        resolvedProfile = nil
        supportConfidence = .experimental
        packetSize = nil
        experimentalApprovalPending = false
        pairingConfirmationPending = false
        pairingStatus = "Not requested"
        pairingCompleted = false
        clearPairingCandidates()
        resumeWhenBluetoothPowersOn = false
        cleanupDiagnostic = nil
        sanitizedOperationOrder.removeAll()
        characteristics.removeAll()
        descriptors.removeAll()
        pendingCharacteristicServices.removeAll()
        timedOutCallbackDebt.removeAll()
        didCompleteIdentityDiscovery = false
        currentIdentity = nil
        rejectedPeripheralIDs.removeAll()
        resumeScanAfterCandidateRejection = false
        releaseAuthorization = nil
        sessionApprovalKey = nil
        acquisition = SonyLocationAcquisition()
        cancelAfterCurrentOperation = false
        compensationErrors.removeAll()
        didStartLocationSetup = false
        attemptOrigin = .none
        stopTimer()
        stopOperationTimeout()
        reconnectRetryTimer?.invalidate()
        reconnectRetryTimer = nil
        operationQueue.removeAll()
        pendingOperation = nil
        onQueueEmpty = nil
    }

    func connectToRememberedCameraOrScan() {
        if connectToRememberedCamera(reason: "remembered camera reconnect") {
            return
        }
        scanForCamera()
    }

    @discardableResult
    func armBackgroundReconnect(reason: String) -> Bool {
        guard backgroundLinkEnabled, !manualStopRequested else { return false }
        guard centralManager.state == .poweredOn else {
            resumeWhenBluetoothPowersOn = true
            state = .bluetoothUnavailable
            appendLog("Waiting for Bluetooth before pending reconnect: \(centralManager.state.rawValue)")
            return false
        }
        if connectToRememberedCamera(reason: reason) {
            return true
        }
        appendLog("No remembered camera for pending reconnect; falling back to scan")
        scanForCamera()
        return false
    }

    func connectToRememberedCamera(reason: String) -> Bool {
        guard let rememberedPeripheralID,
            let identifier = UUID(uuidString: rememberedPeripheralID)
        else {
            return false
        }
        guard hasValidatedRememberedProtocolContext(peripheralID: rememberedPeripheralID) else {
            appendLog("Remembered camera lacks validated protocol context; using advertisement scan")
            return false
        }
        let peripherals = centralManager.retrievePeripherals(withIdentifiers: [identifier])
        guard let rememberedPeripheral = peripherals.first else {
            appendLog("Remembered camera not available for direct reconnect")
            return false
        }

        startConnectionStageTimeout(.connecting)
        switch rememberedPeripheral.state {
        case .connected:
            appendLog("Remembered camera already connected; discovering services")
            pendingReconnectArmed = attemptOrigin == .background
            peripheral = rememberedPeripheral
            beginServiceDiscovery(for: rememberedPeripheral)
        case .connecting:
            appendLog("Pending reconnect already armed for remembered camera")
            pendingReconnectArmed = true
            state = .connecting
            peripheral = rememberedPeripheral
        case .disconnected, .disconnecting:
            appendLog("Arming pending reconnect to remembered camera (\(reason))")
            pendingReconnectArmed = true
            state = .connecting
            peripheral = rememberedPeripheral
            rememberedPeripheral.delegate = self
            centralManager.connect(rememberedPeripheral, options: connectOptions)
        @unknown default:
            appendLog("Arming pending reconnect to remembered camera (\(reason))")
            pendingReconnectArmed = true
            state = .connecting
            peripheral = rememberedPeripheral
            rememberedPeripheral.delegate = self
            centralManager.connect(rememberedPeripheral, options: connectOptions)
        }
        return true
    }

    func hasValidatedRememberedProtocolContext(peripheralID: String) -> Bool {
        guard let record = identityStore.load() else { return false }
        return record.peripheralID == peripheralID && record.identity.protocolVersion != nil
    }

    func disarmPendingReconnect() {
        reconnectRetryTimer?.invalidate()
        reconnectRetryTimer = nil
        pendingReconnectArmed = false
    }

    func scheduleReconnectRetry(reason: String) {
        guard backgroundLinkEnabled, !manualStopRequested else { return }
        reconnectRetryTimer?.invalidate()
        let retryInterval =
            lowPowerModeEnabled
            ? CameraBLEDefaults.lowPowerReconnectRetryInterval
            : CameraBLEDefaults.foregroundReconnectRetryInterval
        appendLog("Scheduling pending reconnect retry in \(Int(retryInterval))s (\(reason))")
        reconnectRetryTimer = Timer.scheduledTimer(withTimeInterval: retryInterval, repeats: false) { [weak self] _ in
            self?.armBackgroundReconnect(reason: "scheduled retry")
        }
    }

    func scanForCamera() {
        state = .scanning
        if attemptOrigin == .background {
            pendingReconnectArmed = true
        }
        startConnectionStageTimeout(.scanning)
        let mode = attemptOrigin == .background ? "background" : "foreground"
        appendLog("Scanning for a Sony camera (\(mode); iOS may throttle background scans)")
        centralManager.scanForPeripherals(
            withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func beginServiceDiscovery(for peripheral: CBPeripheral) {
        state = .discovering
        startConnectionStageTimeout(.discovering)
        peripheral.delegate = self
        detectedFirmware = nil
        resolvedProfile = nil
        supportConfidence = .experimental
        packetSize = nil
        dd21ConfigHex = nil
        currentIdentity = nil
        releaseAuthorization = nil
        sessionApprovalKey = nil
        experimentalApprovalPending = false
        pairingConfirmationPending = false
        descriptors.removeAll()
        pendingCharacteristicServices.removeAll()
        didCompleteIdentityDiscovery = false
        let serviceUUIDs = [
            CBUUID(string: SonyProtocol.cameraControlServiceUUID),
            CBUUID(string: SonyProtocol.locationServiceUUID),
            CBUUID(string: SonyProtocol.pairingServiceUUID),
        ]
        peripheral.discoverServices(serviceUUIDs)
    }

    func beginIdentityDiscovery() {
        guard !didCompleteIdentityDiscovery else { return }
        operationQueue.removeAll()
        if descriptor(SonyProtocol.cameraModelUUID)?.properties.contains(.read) == true {
            enqueueRead(name: "CC0B model", uuid: SonyProtocol.cameraModelUUID, required: false) { [weak self] data in
                self?.discoveredCameraName = self?.decodeIdentity(data)
            }
        }
        if descriptor(SonyProtocol.firmwareVersionUUID)?.properties.contains(.read) == true {
            enqueueRead(name: "CC0A firmware", uuid: SonyProtocol.firmwareVersionUUID, required: false) {
                [weak self] data in
                self?.detectedFirmware = self?.decodeIdentity(data)
            }
        }
        onQueueEmpty = { [weak self] in
            self?.resolveDiscoveredProfile()
        }
        runNextOperationIfNeeded()
    }

    func resolveDiscoveredProfile() {
        guard activeSessionRequested, !manualStopRequested else { return }
        didCompleteIdentityDiscovery = true
        let model = discoveredCameraName ?? peripheral?.name ?? "Unknown Sony camera"
        let fingerprint = SonyLocationCapabilityResolver.descriptorFingerprint(descriptors)
        let stored = identityStore.load()
        var protocolVersion = advertisementProtocolVersion
        if protocolVersion == nil,
            let stored,
            stored.peripheralID == peripheral?.identifier.uuidString,
            stored.identity.normalizedModel
                == SonyCameraIdentity(
                    model: model,
                    firmware: detectedFirmware,
                    protocolVersion: nil
                ).normalizedModel,
            stored.identity.firmware == detectedFirmware,
            stored.descriptorFingerprint == fingerprint
        {
            protocolVersion = stored.identity.protocolVersion
        }

        let identity = SonyCameraIdentity(model: model, firmware: detectedFirmware, protocolVersion: protocolVersion)
        let profile = SonyLocationCapabilityResolver.resolve(
            protocolVersion: protocolVersion,
            descriptors: descriptors,
            discoveryComplete: pendingCharacteristicServices.isEmpty
        )
        let compatibility = SonyLocationCapabilityResolver.compatibility(identity: identity, profile: profile)
        if let stored,
            !stored.matches(
                peripheralID: peripheral?.identifier.uuidString ?? "",
                identity: identity,
                profile: profile,
                descriptors: descriptors
            )
        {
            identityStore.clear()
        }

        currentIdentity = identity
        targetName = identity.model
        advertisementProtocolVersion = protocolVersion
        resolvedProfile = profile

        switch releasePolicy.evaluate(
            identity: identity,
            profile: profile,
            descriptors: descriptors,
            genericCompatibility: compatibility,
            requiresPairingEndpoint: connectionIntent == .pairing
        ) {
        case .unsupported(let rejection):
            supportConfidence = .unsupported
            appendResolvedProfile(identity: identity, profile: profile)
            if rejection.shouldContinueScanning, peripheral != nil, connectionIntent != .pairing {
                skipCurrentCandidateAndContinueScanning(rejection.message)
            } else {
                rejectUnsupportedProfile(rejection.message)
            }
        case .proceed(let authorization):
            releaseAuthorization = authorization
            supportConfidence = authorization.confidence
            appendResolvedProfile(identity: identity, profile: profile)
            if connectionIntent == .pairing {
                // DD21 is a location preflight, not a prerequisite for first-time pairing.
                completeReadOnlyPreflight()
            } else {
                beginDD21Preflight()
            }
        }
    }

    func appendResolvedProfile(identity: SonyCameraIdentity, profile: SonyLocationProfile) {
        appendLog(
            "Resolved model=\(identity.normalizedModel) firmware=\(identity.firmware ?? "unknown") "
                + "protocol=\(identity.protocolVersion.map(String.init) ?? "unknown") "
                + "profile=\(profile.kind.rawValue) confidence=\(supportConfidence.rawValue) "
                + "distribution=\(releasePolicy.mode)"
        )
    }

    func beginDD21Preflight() {
        guard let authorization = releaseAuthorization else { return }
        state = .discovering
        startConnectionStageTimeout(.preparing)
        enqueueRead(name: "DD21 preflight", uuid: SonyProtocol.locationConfigReadUUID, required: true) {
            [weak self] data in
            guard let self else { return }
            let mode = try SonyLocationCapabilityResolver.parseDD21(data)
            try self.releasePolicy.validateDD21(mode, authorization: authorization)
            self.dd21ConfigHex = mode.valueHex
            self.includeTimezone = mode.includeTimezone
            self.packetSize = mode.packetSize
            self.appendLog("DD21 preflight validated; packetSize=\(mode.packetSize)")
        }
        onQueueEmpty = { [weak self] in
            self?.completeReadOnlyPreflight()
        }
        runNextOperationIfNeeded()
    }

    func completeReadOnlyPreflight() {
        guard let authorization = releaseAuthorization else { return }
        if authorization.requiresExperimentalApproval {
            guard releasePolicy.allowsExperimentalApproval else {
                rejectUnsupportedProfile("Experimental camera writes are unavailable in this build.")
                return
            }
            cancelConnectionStageTimeout()
            experimentalApprovalPending = true
            state = .awaitingApproval
            return
        }
        if connectionIntent == .pairing {
            presentPairingConfirmation()
        } else {
            beginLocationSetup()
        }
    }

    func approveExperimentalProfile() {
        guard releasePolicy.allowsExperimentalApproval,
            experimentalApprovalPending,
            releaseAuthorization?.requiresExperimentalApproval == true,
            let identity = currentIdentity,
            let profile = resolvedProfile,
            profile.isExecutable
        else { return }
        sessionApprovalKey = approvalKey(identity: identity, profile: profile)
        experimentalApprovalPending = false
        foregroundTimeoutSession.begin()
        appendLog("Experimental profile approved for this session")
        if connectionIntent == .pairing {
            presentPairingConfirmation()
        } else {
            beginLocationSetup()
        }
    }

    func beginLocationSetup() {
        guard !didStartLocationSetup,
            let profile = resolvedProfile,
            let authorization = releaseAuthorization
        else { return }
        guard !authorization.requiresExperimentalApproval || sessionApprovalKey == expectedApprovalKey else {
            guard releasePolicy.allowsExperimentalApproval else {
                rejectUnsupportedProfile("Experimental camera writes are unavailable in this build.")
                return
            }
            experimentalApprovalPending = true
            state = .awaitingApproval
            return
        }
        guard packetSize != nil else {
            rejectUnsupportedProfile("DD21 preflight did not produce a supported packet size.")
            return
        }
        didStartLocationSetup = true
        state = .enablingLocation
        startConnectionStageTimeout(.preparing)
        let plan = sessionPlanner.makePlan(profile: profile)
        appendLog("Executing Sony \(plan.profile.rawValue) location plan")
        sessionExecutor.execute(plan: plan) { [weak self] action in
            self?.enqueue(action)
        }
        onQueueEmpty = { [weak self] in
            self?.startSendingLocations()
        }
        runNextOperationIfNeeded()
    }

    func remember(peripheral: CBPeripheral) {
        let identifier = peripheral.identifier.uuidString
        guard rememberedPeripheralID != identifier else { return }
        rememberedPeripheralID = identifier
        UserDefaults.standard.set(identifier, forKey: CameraBLEDefaults.rememberedPeripheralID)
        appendLog("Remembered camera for private direct reconnect")
    }
}
