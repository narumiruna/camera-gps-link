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
    @Published var lowPowerModeEnabled = UserDefaults.standard.object(
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
        updateInterval = lowPowerModeEnabled
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
        let didChange = self.backgroundLinkEnabled != backgroundLinkEnabled
            || self.lowPowerModeEnabled != lowPowerModeEnabled
        self.backgroundLinkEnabled = backgroundLinkEnabled
        self.lowPowerModeEnabled = lowPowerModeEnabled
        updateInterval = lowPowerModeEnabled
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
        let retryInterval = lowPowerModeEnabled
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
        centralManager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
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
            enqueueRead(name: "CC0A firmware", uuid: SonyProtocol.firmwareVersionUUID, required: false) { [weak self] data in
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
           stored.identity.normalizedModel == SonyCameraIdentity(
               model: model,
               firmware: detectedFirmware,
               protocolVersion: nil
           ).normalizedModel,
           stored.identity.firmware == detectedFirmware,
           stored.descriptorFingerprint == fingerprint {
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
           ) {
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

    var expectedApprovalKey: String? {
        guard let identity = currentIdentity, let profile = resolvedProfile else { return nil }
        return approvalKey(identity: identity, profile: profile)
    }

    func enqueue(_ action: SonyLocationAction) {
        switch action.kind {
        case let .notify(enabled):
            enqueueNotify(name: action.name, uuid: action.uuid, enabled: enabled, required: action.required)
        case let .write(data):
            enqueueWrite(name: action.name, uuid: action.uuid, data: data, required: action.required)
        case .read:
            if action.uuid.lowercased() == SonyProtocol.locationConfigReadUUID.lowercased() {
                enqueueRead(name: action.name, uuid: action.uuid, required: action.required) { [weak self] data in
                    guard let self else { return }
                    let mode = try SonyLocationCapabilityResolver.parseDD21(data)
                    self.dd21ConfigHex = mode.valueHex
                    self.includeTimezone = mode.includeTimezone
                    self.packetSize = mode.packetSize
                    self.appendLog("DD21 validated; packetSize=\(mode.packetSize)")
                }
            } else {
                enqueueRead(name: action.name, uuid: action.uuid, required: action.required)
            }
        }
    }

    func decodeIdentity(_ data: Data) -> String? {
        guard let value = String(data: data, encoding: .ascii)?
            .trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines)),
            !value.isEmpty,
            value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value <= 0x7E })
        else { return nil }
        return value
    }

    func sendLocationNow() {
        sendLocationIfDue(force: true)
    }

    func sendLocationIfDue(force: Bool = false) {
        guard state == .linked else { return }
        if !force, let lastSentAt, Date().timeIntervalSince(lastSentAt) < updateInterval {
            return
        }
        sendLocationOnce()
    }

    func startSendingLocations() {
        cancelConnectionStageTimeout()
        pendingReconnectArmed = false
        state = .linked
        appendLog(
            "Location link active; interval=\(Int(updateInterval))s; send photos only after DD11 location OK / Packets sent > 0"
        )
        sendLocationOnce()
        restartSendTimer()
    }

    func restartSendTimer() {
        stopTimer()
        sendTimer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { [weak self] _ in
            self?.sendLocationOnce()
        }
    }

    func sendLocationOnce() {
        guard pendingOperation == nil else {
            appendLog("Skipping location send because a BLE operation is still pending")
            return
        }
        guard let location = locationProvider?() else {
            appendLog("No GPS fix available yet; waiting for iPhone location")
            return
        }
        guard location.horizontalAccuracy >= 0 else {
            appendLog("Ignoring invalid GPS fix")
            return
        }
        guard Self.isLocationFresh(
            location.timestamp,
            relativeTo: Date(),
            maximumAge: maximumLocationAge,
            maximumFutureSkew: maximumFutureLocationSkew
        ) else {
            appendLog("Skip DD11: location fix is stale or future-dated")
            return
        }

        do {
            let packet = try SonyProtocol.encodeLocationPacket(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                date: Date(),
                includeTimezone: includeTimezone
            )
            appendLog(
                String(
                    format: "Queue DD11 acc=±%.0fm age=%.0fs bytes=%d coordinate=[REDACTED]",
                    location.horizontalAccuracy,
                    Date().timeIntervalSince(location.timestamp),
                    packet.count
                )
            )
            enqueueWrite(name: "DD11 location", uuid: SonyProtocol.locationDataWriteUUID, data: packet, required: true)
            runNextOperationIfNeeded()
        } catch {
            fail("Failed to encode location packet: \(error.localizedDescription)")
        }
    }

    func enqueueWrite(name: String, uuid: String, data: Data, required: Bool) {
        operationQueue.append(
            QueuedBLEOperation(name: name, required: required) { [weak self] in
                self?.startWrite(name: name, uuid: uuid, data: data, required: required)
            }
        )
    }

    func enqueueRead(
        name: String,
        uuid: String,
        required: Bool,
        onValue: ((Data) throws -> Void)? = nil
    ) {
        operationQueue.append(
            QueuedBLEOperation(name: name, required: required) { [weak self] in
                self?.startRead(name: name, uuid: uuid, required: required, onValue: onValue)
            }
        )
    }

    func enqueueNotify(name: String, uuid: String, enabled: Bool, required: Bool) {
        operationQueue.append(
            QueuedBLEOperation(name: name, required: required) { [weak self] in
                self?.startNotify(name: name, uuid: uuid, enabled: enabled, required: required)
            }
        )
    }

    func runNextOperationIfNeeded() {
        guard pendingOperation == nil else { return }
        guard !operationQueue.isEmpty else {
            let callback = onQueueEmpty
            onQueueEmpty = nil
            callback?()
            return
        }
        let operation = operationQueue.removeFirst()
        sanitizedOperationOrder.append(operation.name)
        appendLog("BLE operation: \(operation.name)")
        operation.start()
    }

    func startWrite(name: String, uuid: String, data: Data, required: Bool) {
        guard let peripheral, let characteristic = characteristic(uuid) else {
            completeOperation(name: name, error: "Missing characteristic \(uuid)", required: required)
            return
        }
        pendingOperation = .write(name: name, uuid: normalized(uuid), required: required)
        startOperationTimeout()

        guard characteristic.properties.contains(.write) else {
            completeOperation(name: name, error: "Characteristic \(uuid) lacks write-with-response", required: required)
            return
        }
        acquisition.recordAttempt(actionName: name)
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
    }

    func startRead(name: String, uuid: String, required: Bool, onValue: ((Data) throws -> Void)?) {
        guard let peripheral, let characteristic = characteristic(uuid) else {
            completeOperation(name: name, error: "Missing characteristic \(uuid)", required: required)
            return
        }
        pendingOperation = .read(name: name, uuid: normalized(uuid), required: required, onValue: onValue)
        startOperationTimeout()
        peripheral.readValue(for: characteristic)
    }

    func startNotify(name: String, uuid: String, enabled: Bool, required: Bool) {
        guard let peripheral, let characteristic = characteristic(uuid) else {
            completeOperation(name: name, error: "Missing characteristic \(uuid)", required: required)
            return
        }
        pendingOperation = .notify(name: name, uuid: normalized(uuid), required: required, enabled: enabled)
        startOperationTimeout()
        if enabled {
            acquisition.recordAttempt(actionName: name)
        }
        peripheral.setNotifyValue(enabled, for: characteristic)
    }

    func completeOperation(name: String, error: String?, required: Bool) {
        pendingOperation = nil
        stopOperationTimeout()
        if let error {
            appendLog("\(name) failed: \(error)")
            if name.hasPrefix("DD31 disable") || name.hasPrefix("DD30 unlock") || name.hasPrefix("DD01 notify stop") {
                compensationErrors.append("\(name): \(error)")
            }
            if cancelAfterCurrentOperation {
                cancelAfterCurrentOperation = false
                beginCompensation(finalState: .stopped, disconnectAfter: true)
                return
            }
            if required {
                if name == "EE01 pairing init" {
                    pairingStatus = "Pairing initialization failed: \(error)"
                }
                fail(error)
                return
            }
        } else {
            appendLog("\(name) OK")
            acquisition.recordSuccess(actionName: name)
            if name == "DD31 disable" { acquisition.dd31 = false }
            if name == "DD30 unlock" { acquisition.dd30 = false }
            if name == "DD01 notify stop" { acquisition.dd01 = false }
            if name == "DD11 location" {
                packetsSent += 1
                lastSentAt = Date()
                persistValidatedIdentity()
            }
        }
        if cancelAfterCurrentOperation {
            cancelAfterCurrentOperation = false
            beginCompensation(finalState: .stopped, disconnectAfter: true)
            return
        }
        runNextOperationIfNeeded()
    }

    func fail(_ message: String) {
        cancelConnectionStageTimeout()
        manualStopRequested = true
        activeSessionRequested = false
        lastError = message
        state = .failed
        stopTimer()
        operationQueue.removeAll()
        appendLog("Failed: \(message)")
        guard pendingOperation == nil else {
            cancelAfterCurrentOperation = true
            return
        }
        beginCompensation(finalState: .failed, disconnectAfter: true)
    }

    func beginCompensation(finalState: CameraConnectionState, disconnectAfter: Bool) {
        operationQueue.removeAll()
        onQueueEmpty = nil
        compensationInProgress = true
        guard peripheral != nil else {
            let cleanupNeeded = !acquisition.compensation.isEmpty
            if cleanupDiagnostic?.hasPrefix("Incomplete cleanup") != true {
                cleanupDiagnostic = cleanupNeeded ? "Incomplete cleanup: camera is disconnected" : "Cleanup not needed"
            }
            if cleanupNeeded {
                activeSessionRequested = false
                manualStopRequested = true
                setUserLinkIntent(active: false)
                lastError = cleanupDiagnostic
            }
            compensationInProgress = false
            state = cleanupNeeded ? .failed : finalState
            return
        }
        compensationErrors.removeAll()
        let compensation = acquisition.compensation
        if !compensation.isEmpty {
            state = .stopping
        }
        for action in compensation {
            enqueue(action)
        }
        onQueueEmpty = { [weak self] in
            guard let self else { return }
            self.compensationInProgress = false
            if self.compensationErrors.isEmpty {
                self.cleanupDiagnostic = "Cleanup complete"
            } else {
                self.cleanupDiagnostic = "Incomplete cleanup: " + self.compensationErrors.joined(separator: "; ")
            }
            self.state = finalState
            if disconnectAfter, let peripheral = self.peripheral {
                self.centralManager.cancelPeripheralConnection(peripheral)
            } else if self.peripheral == nil {
                self.state = finalState
            }
        }
        runNextOperationIfNeeded()
    }

    func persistValidatedIdentity() {
        guard let peripheral, let identity = currentIdentity, let profile = resolvedProfile else { return }
        identityStore.save(
            SonyValidatedIdentityRecord(
                peripheralID: peripheral.identifier.uuidString,
                identity: identity,
                profile: profile.kind,
                descriptorFingerprint: SonyLocationCapabilityResolver.descriptorFingerprint(descriptors)
            )
        )
    }

    func stopTimer() {
        sendTimer?.invalidate()
        sendTimer = nil
    }

    func startOperationTimeout() {
        stopOperationTimeout()
        operationTimeoutTimer = Timer.scheduledTimer(withTimeInterval: operationTimeout, repeats: false) { [weak self] _ in
            self?.handleOperationTimeout()
        }
    }

    func stopOperationTimeout() {
        operationTimeoutTimer?.invalidate()
        operationTimeoutTimer = nil
    }

    func startConnectionStageTimeout(_ stage: ForegroundConnectionStage) {
        foregroundTimeoutSession.transition(to: stage)
    }

    func cancelConnectionStageTimeout() {
        foregroundTimeoutSession.end()
    }

    func handleConnectionStageTimeout(stage: ForegroundConnectionStage) {
        manualStopRequested = true
        resumeWhenBluetoothPowersOn = false
        centralManager.stopScan()
        pendingReconnectArmed = false
        let message = "\(stage.userFacingName) timed out. Make sure the camera is nearby and ready for its Bluetooth location link."
        fail(message)
    }

    func handleOperationTimeout() {
        guard let pendingOperation else { return }
        recordTimedOutCallback(for: pendingOperation)
        self.pendingOperation = nil
        appendLog("\(pendingOperation.name) timed out after \(Int(operationTimeout))s")
        if pendingOperation.name.hasPrefix("DD31 disable")
            || pendingOperation.name.hasPrefix("DD30 unlock")
            || pendingOperation.name.hasPrefix("DD01 notify stop") {
            compensationErrors.append("\(pendingOperation.name): timed out")
        }
        if cancelAfterCurrentOperation {
            cancelAfterCurrentOperation = false
            beginCompensation(finalState: .stopped, disconnectAfter: true)
        } else if pendingOperation.required {
            fail("\(pendingOperation.name) timed out")
        } else {
            runNextOperationIfNeeded()
        }
    }

    func appendLog(_ message: String) {
        let timestamp = Date().formatted(date: .omitted, time: .standard)
        let line = "\(timestamp)  \(message)"
        diagnosticsStore.append(line)
        let sanitizedLine = diagnosticsStore.lines.last ?? "Diagnostic event [REDACTED]"
        print(sanitizedLine)
        logger.info("\(sanitizedLine, privacy: .public)")
    }

    func remember(peripheral: CBPeripheral) {
        let identifier = peripheral.identifier.uuidString
        guard rememberedPeripheralID != identifier else { return }
        rememberedPeripheralID = identifier
        UserDefaults.standard.set(identifier, forKey: CameraBLEDefaults.rememberedPeripheralID)
        appendLog("Remembered camera for private direct reconnect")
    }


}
