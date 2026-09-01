import CoreBluetooth
import Foundation

extension CameraBLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            appendLog("Bluetooth powered on")
            if state == .bluetoothUnavailable {
                state = .idle
            }
            if resumeWhenBluetoothPowersOn {
                resumeWhenBluetoothPowersOn = false
                guard locationProvider != nil else {
                    appendLog("Background link waiting for location provider")
                    return
                }
                armBackgroundReconnect(reason: "Bluetooth powered on")
            }
        case .poweredOff, .unauthorized, .unsupported, .resetting, .unknown:
            cancelConnectionStageTimeout()
            if Self.disconnectLeavesCleanupIncomplete(acquisition) {
                stopTimer()
                stopOperationTimeout()
                operationQueue.removeAll()
                pendingOperation = nil
                onQueueEmpty = nil
                disarmPendingReconnect()
                activeSessionRequested = false
                manualStopRequested = true
                setUserLinkIntent(active: false)
                cleanupDiagnostic =
                    "Incomplete cleanup: Bluetooth became unavailable while camera controls might be active"
                lastError = cleanupDiagnostic
                state = .failed
            } else {
                state = .bluetoothUnavailable
            }
            appendLog("Bluetooth state changed: \(central.state.rawValue)")
        @unknown default:
            state = .bluetoothUnavailable
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi: NSNumber
    ) {
        guard !manualStopRequested, !rejectedPeripheralIDs.contains(peripheral.identifier) else { return }
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? localName ?? ""
        let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let info = SonyProtocol.parseAdvertisement(manufacturerData: manufacturerData)
        let matchesName =
            name.localizedCaseInsensitiveContains(targetName) || name.localizedCaseInsensitiveContains("ILCE-")
        let matchesSonyCamera = info?.isCamera == true

        guard matchesName || matchesSonyCamera else { return }

        discoveredCameraName = name.isEmpty ? "Sony camera" : name
        appendLog("Found \(discoveredCameraName ?? "Sony camera") RSSI=\(rssi)")
        advertisementProtocolVersion = info?.protocolVersion
        if let info {
            appendLog("Sony protocolVersion=\(info.protocolVersion.map(String.init) ?? "unknown")")
        }
        state = .connecting
        startConnectionStageTimeout(.connecting)
        pendingReconnectArmed = false
        central.stopScan()
        self.peripheral = peripheral
        remember(peripheral: peripheral)
        central.connect(peripheral, options: connectOptions)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard !manualStopRequested else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        appendLog("Connected")
        pendingReconnectArmed = attemptOrigin == .background
        reconnectRetryTimer?.invalidate()
        reconnectRetryTimer = nil
        remember(peripheral: peripheral)
        beginServiceDiscovery(for: peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let wasForegroundAttempt = attemptOrigin == .foreground
        cancelConnectionStageTimeout()
        appendLog(error?.localizedDescription ?? "Failed to connect")
        pendingReconnectArmed = false
        self.peripheral = nil
        if wasForegroundAttempt {
            fail(error?.localizedDescription ?? "Failed to connect")
            return
        }
        guard backgroundLinkEnabled, !manualStopRequested else {
            fail(error?.localizedDescription ?? "Failed to connect")
            return
        }
        scheduleReconnectRetry(reason: error?.localizedDescription ?? "connect failed")
        scanForCamera()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let shouldResumeCandidateScan = resumeScanAfterCandidateRejection && !manualStopRequested
        if !shouldResumeCandidateScan {
            resumeScanAfterCandidateRejection = false
        }
        let wasForegroundAttempt = attemptOrigin == .foreground && state != .linked
        cancelConnectionStageTimeout()
        appendLog("Disconnected")
        let hadPossiblyAppliedControls = Self.disconnectLeavesCleanupIncomplete(acquisition)
        let cleanupWasIncomplete = hadPossiblyAppliedControls
        if hadPossiblyAppliedControls {
            if cleanupDiagnostic?.hasPrefix("Incomplete cleanup") != true {
                cleanupDiagnostic = "Incomplete cleanup: camera disconnected before controls were confirmed released"
            }
            appendLog(cleanupDiagnostic ?? "Incomplete cleanup")
        }
        acquisition = SonyLocationAcquisition()
        self.peripheral = nil
        stopTimer()
        stopOperationTimeout()
        operationQueue.removeAll()
        pendingOperation = nil
        timedOutCallbackDebt.removeAll()
        characteristics.removeAll()
        didStartLocationSetup = false

        if cleanupWasIncomplete {
            compensationInProgress = false
            activeSessionRequested = false
            manualStopRequested = true
            setUserLinkIntent(active: false)
            lastError = cleanupDiagnostic
            state = .failed
            return
        }
        if shouldResumeCandidateScan {
            compensationInProgress = false
            resumeScanningAfterCandidateRejection()
            return
        }
        if state == .stopping {
            compensationInProgress = false
            activeSessionRequested = false
            state = .stopped
            return
        }
        if state == .stopped || state == .failed || state == .unsupported {
            compensationInProgress = false
            return
        }
        if wasForegroundAttempt {
            fail(error?.localizedDescription ?? "Camera disconnected while connecting.")
            return
        }
        guard backgroundLinkEnabled, !manualStopRequested else {
            if hadPossiblyAppliedControls {
                lastError = cleanupDiagnostic
                state = .failed
            } else if let error {
                fail(error.localizedDescription)
            } else {
                state = .idle
            }
            return
        }

        let retainedCleanupDiagnostic = cleanupDiagnostic
        appendLog("Background link will arm pending reconnect after disconnect")
        prepareForNewSession(resetCounters: true)
        cleanupDiagnostic = retainedCleanupDiagnostic
        connectionIntent = .location
        attemptOrigin = .background
        activeSessionRequested = true
        armBackgroundReconnect(reason: "peripheral disconnected")
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        appendLog("CoreBluetooth restored state")
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
            let restoredPeripheral = peripherals.first
        {
            appendLog("Restored remembered camera state=\(restoredPeripheral.state.rawValue)")
            guard backgroundLinkEnabled, userLinkIntentActive else {
                remember(peripheral: restoredPeripheral)
                if restoredPeripheral.state == .connected {
                    central.cancelPeripheralConnection(restoredPeripheral)
                }
                appendLog("Restored camera retained privately; no active link intent")
                return
            }
            manualStopRequested = false
            prepareForNewSession(resetCounters: true)
            connectionIntent = .location
            attemptOrigin = .background
            activeSessionRequested = true
            peripheral = restoredPeripheral
            restoredPeripheral.delegate = self
            remember(peripheral: restoredPeripheral)
            if restoredPeripheral.state == .connected {
                pendingReconnectArmed = true
                beginServiceDiscovery(for: restoredPeripheral)
            } else if backgroundLinkEnabled {
                pendingReconnectArmed = true
                state = .connecting
                central.connect(restoredPeripheral, options: connectOptions)
            }
        }
    }
}

extension CameraBLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard !manualStopRequested else { return }
        if let error {
            fail(error.localizedDescription)
            return
        }
        let supportedServices = Set(
            [
                SonyProtocol.cameraControlServiceUUID,
                SonyProtocol.locationServiceUUID,
                SonyProtocol.pairingServiceUUID,
            ].map(normalized)
        )
        let services = (peripheral.services ?? []).filter { supportedServices.contains(normalized($0.uuid)) }
        pendingCharacteristicServices = Set(services.map { normalized($0.uuid) })
        guard !services.isEmpty else {
            beginIdentityDiscovery()
            return
        }
        for service in services {
            let serviceID = normalized(service.uuid)
            let uuidStrings: [String]
            if serviceID == normalized(SonyProtocol.cameraControlServiceUUID) {
                uuidStrings = [SonyProtocol.firmwareVersionUUID, SonyProtocol.cameraModelUUID]
            } else if serviceID == normalized(SonyProtocol.locationServiceUUID) {
                uuidStrings = [
                    SonyProtocol.locationStatusNotifyUUID,
                    SonyProtocol.locationDataWriteUUID,
                    SonyProtocol.locationConfigReadUUID,
                    SonyProtocol.locationLockUUID,
                    SonyProtocol.locationEnableUUID,
                    SonyProtocol.timeCorrectionUUID,
                    SonyProtocol.areaAdjustmentUUID,
                ]
            } else {
                uuidStrings = [SonyProtocol.pairingInitUUID]
            }
            peripheral.discoverCharacteristics(uuidStrings.map(CBUUID.init(string:)), for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard !manualStopRequested else { return }
        if let error {
            fail(error.localizedDescription)
            return
        }
        for characteristic in service.characteristics ?? [] {
            characteristics[
                endpointKey(service: service.uuid.uuidString, characteristic: characteristic.uuid.uuidString)] =
                characteristic
            descriptors.append(
                SonyGattDescriptor(
                    serviceUUID: service.uuid.uuidString,
                    characteristicUUID: characteristic.uuid.uuidString,
                    properties: sonyProperties(characteristic.properties)
                )
            )
            appendLog("Characteristic \(characteristic.uuid.uuidString) properties discovered")
        }
        pendingCharacteristicServices.remove(normalized(service.uuid))
        if pendingCharacteristicServices.isEmpty {
            beginIdentityDiscovery()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard isExpectedEndpoint(characteristic, from: peripheral) else { return }
        if consumeTimedOutCallback(kind: "write", uuid: characteristic.uuid.uuidString) { return }
        guard
            case .write(let name, let uuid, let required) = pendingOperation,
            uuid == normalized(characteristic.uuid)
        else {
            return
        }
        completeOperation(name: name, error: error?.localizedDescription, required: required)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard isExpectedEndpoint(characteristic, from: peripheral) else { return }
        let characteristicUUID = normalized(characteristic.uuid)
        if consumeTimedOutCallback(kind: "read", uuid: characteristicUUID) { return }
        if case .read(let name, let uuid, let required, let onValue) = pendingOperation, uuid == characteristicUUID {
            if let error {
                completeOperation(name: name, error: error.localizedDescription, required: required)
                return
            }
            let data = characteristic.value ?? Data()
            do {
                try onValue?(data)
            } catch {
                if name == "DD21 preflight" {
                    handleDD21PreflightValidationFailure(error.localizedDescription)
                } else {
                    completeOperation(name: name, error: error.localizedDescription, required: required)
                }
                return
            }
            completeOperation(name: name, error: nil, required: required)
            return
        }

        if characteristicUUID == normalized(SonyProtocol.locationStatusNotifyUUID), let data = characteristic.value {
            appendLog("DD01 notify received bytes=\(data.count) payload=[REDACTED]")
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?
    ) {
        guard isExpectedEndpoint(characteristic, from: peripheral) else { return }
        let characteristicUUID = normalized(characteristic.uuid)
        if consumeTimedOutCallback(kind: "notify", uuid: characteristicUUID) { return }
        if case .notify(let name, let uuid, let required, let enabled) = pendingOperation, uuid == characteristicUUID {
            if let error {
                completeOperation(name: name, error: error.localizedDescription, required: required)
                return
            }
            guard characteristic.isNotifying == enabled else {
                completeOperation(name: name, error: "Notify state mismatch", required: required)
                return
            }
            completeOperation(name: name, error: nil, required: required)
            return
        }

        if let error {
            appendLog("Notify state failed for \(characteristic.uuid.uuidString): \(error.localizedDescription)")
        } else {
            appendLog("Notify state \(characteristic.uuid.uuidString) isNotifying=\(characteristic.isNotifying)")
        }
    }
}

struct QueuedBLEOperation {
    let name: String
    let required: Bool
    let start: () -> Void
}

enum PendingBLEOperation {
    case write(name: String, uuid: String, required: Bool)
    case read(name: String, uuid: String, required: Bool, onValue: ((Data) throws -> Void)?)
    case notify(name: String, uuid: String, required: Bool, enabled: Bool)

    var name: String {
        switch self {
        case .write(let name, _, _), .read(let name, _, _, _), .notify(let name, _, _, _):
            name
        }
    }

    var required: Bool {
        switch self {
        case .write(_, _, let required), .read(_, _, let required, _), .notify(_, _, let required, _):
            required
        }
    }

    var callbackDebtKey: String {
        switch self {
        case .write(_, let uuid, _):
            "write|\(uuid)"
        case .read(_, let uuid, _, _):
            "read|\(uuid)"
        case .notify(_, let uuid, _, _):
            "notify|\(uuid)"
        }
    }
}

extension CameraBLEManager {
    func skipCurrentCandidateAndContinueScanning(_ reason: String) {
        guard let peripheral else {
            rejectUnsupportedProfile(reason)
            return
        }
        startConnectionStageTimeout(.connecting)
        stopOperationTimeout()
        operationQueue.removeAll()
        pendingOperation = nil
        onQueueEmpty = nil
        experimentalApprovalPending = false
        pairingConfirmationPending = false
        rejectedPeripheralIDs.insert(peripheral.identifier)
        resumeScanAfterCandidateRejection = true
        appendLog("Skipping non-target camera and continuing scan: \(reason)")
        state = .scanning
        centralManager.cancelPeripheralConnection(peripheral)
    }

    func resumeScanningAfterCandidateRejection() {
        let retainedOrigin = attemptOrigin
        let retainedIntent = connectionIntent
        let retainedRejectedPeripheralIDs = rejectedPeripheralIDs
        prepareForNewSession(resetCounters: false)
        rejectedPeripheralIDs = retainedRejectedPeripheralIDs
        resumeScanAfterCandidateRejection = false
        connectionIntent = retainedIntent
        attemptOrigin = retainedOrigin
        activeSessionRequested = true
        manualStopRequested = false
        discoveredCameraName = nil
        if retainedOrigin == .foreground {
            foregroundTimeoutSession.begin()
        }
        appendLog("Resuming scan for an exact release-policy target")
        scanForCamera()
    }

    func rejectUnsupportedProfile(_ reason: String) {
        cancelConnectionStageTimeout()
        activeSessionRequested = false
        manualStopRequested = true
        attemptOrigin = .none
        setUserLinkIntent(active: false)
        experimentalApprovalPending = false
        pairingConfirmationPending = false
        lastError = reason
        if connectionIntent == .pairing {
            pairingStatus = "Pairing blocked: \(reason)"
        }
        state = .unsupported
        if let peripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
    }

    func approvalKey(identity: SonyCameraIdentity, profile: SonyLocationProfile) -> String {
        let purpose = connectionIntent == .pairing ? "pair-init" : "location-sync"
        return [
            identity.approvalKey,
            profile.kind.rawValue,
            profile.protocolVersion.map(String.init) ?? "unknown",
            profile.hasStatusNotifications ? "notify" : "no-notify",
            profile.hasTimeCorrection ? "time" : "no-time",
            profile.hasAreaAdjustment ? "area" : "no-area",
            purpose,
        ].joined(separator: "|")
    }

    func setUserLinkIntent(active: Bool) {
        userLinkIntentActive = active
        UserDefaults.standard.set(active, forKey: CameraBLEDefaults.activeLinkIntent)
    }

    func recordTimedOutCallback(for operation: PendingBLEOperation) {
        timedOutCallbackDebt[operation.callbackDebtKey, default: 0] += 1
    }

    func consumeTimedOutCallback(kind: String, uuid: String) -> Bool {
        let key = "\(kind)|\(normalized(uuid))"
        guard let count = timedOutCallbackDebt[key], count > 0 else { return false }
        if count == 1 {
            timedOutCallbackDebt.removeValue(forKey: key)
        } else {
            timedOutCallbackDebt[key] = count - 1
        }
        appendLog("Ignored late \(kind) callback for \(normalized(uuid))")
        return true
    }

    static func disconnectLeavesCleanupIncomplete(_ acquisition: SonyLocationAcquisition) -> Bool {
        acquisition.dd30 || acquisition.dd31 || acquisition.dd01
    }

    static func isLocationFresh(
        _ timestamp: Date,
        relativeTo now: Date,
        maximumAge: TimeInterval = 120,
        maximumFutureSkew: TimeInterval = 10
    ) -> Bool {
        let age = now.timeIntervalSince(timestamp)
        return age >= -maximumFutureSkew && age <= maximumAge
    }

    func characteristic(_ uuid: String) -> CBCharacteristic? {
        guard let serviceUUID = expectedServiceUUID(for: uuid) else { return nil }
        return characteristics[endpointKey(service: serviceUUID, characteristic: uuid)]
    }

    func descriptor(_ uuid: String) -> SonyGattDescriptor? {
        guard let expectedService = expectedServiceUUID(for: uuid) else { return nil }
        let expectedCharacteristic = normalized(uuid)
        return descriptors.first {
            normalized($0.serviceUUID) == normalized(expectedService)
                && normalized($0.characteristicUUID) == expectedCharacteristic
        }
    }

    func endpointKey(service: String, characteristic: String) -> String {
        "\(normalized(service))|\(normalized(characteristic))"
    }

    func isExpectedEndpoint(_ characteristic: CBCharacteristic, from callbackPeripheral: CBPeripheral) -> Bool {
        guard let activePeripheral = peripheral,
            activePeripheral === callbackPeripheral,
            let service = characteristic.service,
            let expectedService = expectedServiceUUID(for: characteristic.uuid.uuidString),
            let expectedCharacteristic = self.characteristic(characteristic.uuid.uuidString)
        else { return false }
        return normalized(service.uuid) == normalized(expectedService)
            && expectedCharacteristic === characteristic
    }

    func expectedServiceUUID(for characteristicUUID: String) -> String? {
        let characteristic = normalized(characteristicUUID)
        if characteristic.hasPrefix("cc") { return SonyProtocol.cameraControlServiceUUID }
        if characteristic.hasPrefix("dd") { return SonyProtocol.locationServiceUUID }
        if characteristic.hasPrefix("ee") { return SonyProtocol.pairingServiceUUID }
        return nil
    }

    func sonyProperties(_ properties: CBCharacteristicProperties) -> Set<SonyGattProperty> {
        var result: Set<SonyGattProperty> = []
        if properties.contains(.read) { result.insert(.read) }
        if properties.contains(.write) { result.insert(.write) }
        if properties.contains(.writeWithoutResponse) { result.insert(.writeWithoutResponse) }
        if properties.contains(.notify) { result.insert(.notify) }
        if properties.contains(.indicate) { result.insert(.indicate) }
        return result
    }

    func normalized(_ uuid: String) -> String {
        let lowercased = uuid.lowercased()
        let bluetoothBaseSuffix = "-0000-1000-8000-00805f9b34fb"
        if lowercased.hasPrefix("0000"), lowercased.hasSuffix(bluetoothBaseSuffix) {
            return String(lowercased.dropFirst(4).prefix(4))
        }
        return lowercased
    }

    func normalized(_ uuid: CBUUID) -> String {
        normalized(uuid.uuidString)
    }
}

enum CameraAttemptOrigin {
    case none
    case foreground
    case background
}

enum CameraConnectionIntent {
    case location
    case pairing
}

enum CameraBLEDefaults {
    static let restorationIdentifier = "dev.narumi.cameragpslink.central"
    static let backgroundLinkEnabled = "backgroundLinkEnabled"
    static let lowPowerModeEnabled = "lowPowerModeEnabled"
    static let rememberedPeripheralID = "rememberedPeripheralID"
    static let activeLinkIntent = "activeSonyLocationLinkIntent"
    static let foregroundUpdateInterval: TimeInterval = 30
    static let lowPowerUpdateInterval: TimeInterval = 120
    static let foregroundReconnectRetryInterval: TimeInterval = 30
    static let lowPowerReconnectRetryInterval: TimeInterval = 120
}
