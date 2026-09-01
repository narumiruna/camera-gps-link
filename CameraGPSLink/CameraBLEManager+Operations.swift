import Foundation

extension CameraBLEManager {
    var expectedApprovalKey: String? {
        guard let identity = currentIdentity, let profile = resolvedProfile else { return nil }
        return approvalKey(identity: identity, profile: profile)
    }

    func handleDD21PreflightValidationFailure(_ message: String) {
        pendingOperation = nil
        stopOperationTimeout()
        operationQueue.removeAll()
        onQueueEmpty = nil
        if cancelAfterCurrentOperation {
            cancelAfterCurrentOperation = false
            appendLog("Discarding DD21 validation failure after cancellation")
            beginCompensation(finalState: .stopped, disconnectAfter: true)
            return
        }
        rejectUnsupportedProfile(message)
    }

    func enqueue(_ action: SonyLocationAction) {
        switch action.kind {
        case .notify(let enabled):
            enqueueNotify(name: action.name, uuid: action.uuid, enabled: enabled, required: action.required)
        case .write(let data):
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
        guard
            let value = String(data: data, encoding: .ascii)?
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
        guard state == .linked, permitsLocationWrites else { return }
        if !force, let lastSentAt, Date().timeIntervalSince(lastSentAt) < updateInterval {
            return
        }
        sendLocationOnce()
    }

    func startSendingLocations() {
        guard permitsLocationWrites else {
            appendLog("Foreground-only location link cannot start while the app is in background")
            stopLink()
            return
        }
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
        guard permitsLocationWrites else { return }
        sendTimer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { [weak self] _ in
            self?.sendLocationOnce()
        }
    }

    func sendLocationOnce() {
        guard permitsLocationWrites else {
            appendLog("Skipping DD11 because foreground-only location writes are suspended")
            return
        }
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
        guard
            Self.isLocationFresh(
                location.timestamp,
                relativeTo: Date(),
                maximumAge: maximumLocationAge,
                maximumFutureSkew: maximumFutureLocationSkew
            )
        else {
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
        operationTimeoutTimer = Timer.scheduledTimer(withTimeInterval: operationTimeout, repeats: false) {
            [weak self] _ in
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
        let message =
            "\(stage.userFacingName) timed out. Make sure the camera is nearby and ready for its Bluetooth location link."
        fail(message)
    }

    func handleOperationTimeout() {
        guard let pendingOperation else { return }
        recordTimedOutCallback(for: pendingOperation)
        self.pendingOperation = nil
        appendLog("\(pendingOperation.name) timed out after \(Int(operationTimeout))s")
        if pendingOperation.name.hasPrefix("DD31 disable")
            || pendingOperation.name.hasPrefix("DD30 unlock")
            || pendingOperation.name.hasPrefix("DD01 notify stop")
        {
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

}
