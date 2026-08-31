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
    var sessionApprovalKey: String?
    var acquisition = SonyLocationAcquisition()
    var connectionIntent: CameraConnectionIntent = .location
    var attemptOrigin: CameraAttemptOrigin = .none
    var activeSessionRequested = false
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
    let maximumLocationAge: TimeInterval = 120
    let maximumFutureLocationSkew: TimeInterval = 10
    let diagnosticsStore: DiagnosticsLogStore
    let identityStore: any SonyValidatedIdentityStoring
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

    convenience init(diagnosticsStore: DiagnosticsLogStore) {
        self.init(
            diagnosticsStore: diagnosticsStore,
            timeoutPolicy: ForegroundConnectionTimeoutPolicy(),
            timeoutScheduler: .live
        )
    }

    init(
        diagnosticsStore: DiagnosticsLogStore,
        timeoutPolicy: ForegroundConnectionTimeoutPolicy,
        timeoutScheduler: ConnectionTimeoutScheduler,
        identityStore: any SonyValidatedIdentityStoring = UserDefaultsSonyValidatedIdentityStore(),
        sessionPlanner: any SonyLocationSessionPlanning = DefaultSonyLocationSessionPlanner(),
        sessionExecutor: any SonyLocationSessionExecuting = DefaultSonyLocationSessionExecutor()
    ) {
        self.diagnosticsStore = diagnosticsStore
        self.identityStore = identityStore
        self.sessionPlanner = sessionPlanner
        self.sessionExecutor = sessionExecutor
        super.init()
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

    func configure(backgroundLinkEnabled: Bool, lowPowerModeEnabled: Bool) {
        let didChange =
            self.backgroundLinkEnabled != backgroundLinkEnabled
            || self.lowPowerModeEnabled != lowPowerModeEnabled
        self.backgroundLinkEnabled = backgroundLinkEnabled
        self.lowPowerModeEnabled = lowPowerModeEnabled
        updateInterval =
            lowPowerModeEnabled
            ? CameraBLEDefaults.lowPowerUpdateInterval
            : CameraBLEDefaults.foregroundUpdateInterval
        UserDefaults.standard.set(backgroundLinkEnabled, forKey: CameraBLEDefaults.backgroundLinkEnabled)
        UserDefaults.standard.set(lowPowerModeEnabled, forKey: CameraBLEDefaults.lowPowerModeEnabled)

        if didChange {
            appendLog(
                "BLE settings: backgroundLink=\(backgroundLinkEnabled) lowPower=\(lowPowerModeEnabled) interval=\(Int(updateInterval))s"
            )
        }
        if state == .linked {
            restartSendTimer()
        }
        if !backgroundLinkEnabled {
            disarmPendingReconnect()
        }
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
            resumeWhenBluetoothPowersOn = false
            state = .bluetoothUnavailable
            appendLog("Bluetooth is not powered on: \(centralManager.state.rawValue)")
            return
        }
        connectToRememberedCameraOrScan()
    }

    func resumeBackgroundLink(locationProvider: @escaping () -> CLLocation?) {
        setLocationProvider(locationProvider)
        guard backgroundLinkEnabled else { return }
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

    func cancelCurrentAttempt() {
        appendLog("Cancelling current connection attempt")
        manualStopRequested = true
        setUserLinkIntent(active: false)
        activeSessionRequested = false
        attemptOrigin = .none
        cancelConnectionStageTimeout()
        resumeWhenBluetoothPowersOn = false
        centralManager.stopScan()
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
        cleanupDiagnostic = nil
        sanitizedOperationOrder.removeAll()
        characteristics.removeAll()
        descriptors.removeAll()
        pendingCharacteristicServices.removeAll()
        timedOutCallbackDebt.removeAll()
        didCompleteIdentityDiscovery = false
        currentIdentity = nil
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
        var profile = SonyLocationCapabilityResolver.resolve(
            protocolVersion: protocolVersion,
            descriptors: descriptors,
            discoveryComplete: pendingCharacteristicServices.isEmpty
        )
        var compatibility = SonyLocationCapabilityResolver.compatibility(identity: identity, profile: profile)
        if compatibility.confidence == .unsupported {
            profile = SonyLocationCapabilityResolver.resolve(
                protocolVersion: protocolVersion,
                descriptors: descriptors,
                discoveryComplete: true,
                registryConfidence: .unsupported
            )
            compatibility = SonyCompatibility(confidence: .unsupported, evidence: compatibility.evidence)
        }
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
        supportConfidence = profile.isExecutable ? compatibility.confidence : .unsupported
        appendLog(
            "Resolved model=\(identity.normalizedModel) firmware=\(identity.firmware ?? "unknown") "
                + "protocol=\(identity.protocolVersion.map(String.init) ?? "unknown") "
                + "profile=\(profile.kind.rawValue) confidence=\(supportConfidence.rawValue)"
        )

        guard profile.isExecutable, supportConfidence != .unsupported else {
            rejectUnsupportedProfile(profile.reason)
            return
        }
        if supportConfidence != .verified {
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
        guard experimentalApprovalPending,
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

    func requestPairingInitialization() {
        guard canStart else {
            pairingStatus = "Stop the active location session before starting pairing."
            return
        }
        manualStopRequested = false
        prepareForNewSession(resetCounters: true)
        connectionIntent = .pairing
        attemptOrigin = .foreground
        activeSessionRequested = true
        pairingStatus = "Discovering camera identity before pairing confirmation"
        foregroundTimeoutSession.begin()
        guard centralManager.state == .poweredOn else {
            activeSessionRequested = false
            foregroundTimeoutSession.end()
            state = .bluetoothUnavailable
            pairingStatus = "Bluetooth is unavailable"
            return
        }
        connectToRememberedCameraOrScan()
    }

    func presentPairingConfirmation() {
        guard connectionIntent == .pairing,
            didCompleteIdentityDiscovery,
            descriptor(SonyProtocol.pairingInitUUID)?.properties.contains(.write) == true
        else {
            pairingStatus = "EE01 write-with-response is unavailable in the current session."
            fail(pairingStatus)
            return
        }
        cancelConnectionStageTimeout()
        pairingConfirmationPending = true
        pairingStatus = "Confirmation required for \(currentIdentity?.normalizedModel ?? "unknown camera")"
        state = .pairing
    }

    func confirmPairingInitialization() {
        guard connectionIntent == .pairing,
            pairingConfirmationPending,
            !experimentalApprovalPending,
            currentIdentity != nil
        else { return }
        pairingConfirmationPending = false
        pairingStatus = "Sending explicit EE01 pairing initialization"
        state = .pairing
        enqueueWrite(
            name: "EE01 pairing init",
            uuid: SonyProtocol.pairingInitUUID,
            data: SonyProtocol.pairingInitPayload,
            required: true
        )
        onQueueEmpty = { [weak self] in
            guard let self else { return }
            self.pairingStatus = "Pairing initialization sent"
            self.attemptOrigin = .none
            self.activeSessionRequested = false
            self.state = .stopped
            if let peripheral = self.peripheral {
                self.centralManager.cancelPeripheralConnection(peripheral)
            }
        }
        runNextOperationIfNeeded()
    }

    func cancelPairingInitialization() {
        pairingConfirmationPending = false
        pairingStatus = "Cancelled without a GATT write"
        cancelCurrentAttempt()
    }

    func beginLocationSetup() {
        guard !didStartLocationSetup, let profile = resolvedProfile else { return }
        guard supportConfidence == .verified || sessionApprovalKey == expectedApprovalKey else {
            experimentalApprovalPending = true
            state = .awaitingApproval
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
            guard let self else { return }
            guard self.packetSize != nil else {
                self.fail("DD21 negotiation did not produce a supported packet size")
                return
            }
            self.startSendingLocations()
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
