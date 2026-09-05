import CoreBluetooth
import Foundation

extension CameraBLEManager {
    var pairingSnapshot: CameraPairingSnapshot {
        CameraPairingSnapshot(
            bluetooth: CameraBluetoothAvailability(centralManager.state),
            cameras: pairingCameras,
            canSearch: canStart,
            isPairing: connectionIntent == .pairing,
            waitingForBluetooth: connectionIntent == .pairing && resumeWhenBluetoothPowersOn,
            completed: pairingCompleted
        )
    }

    func clearPairingCandidates() {
        pairingCameras.removeAll()
        pairingPeripherals.removeAll()
    }

    func requestPairingInitialization() {
        beginPairingRequest(bluetoothState: centralManager.state)
    }

    func beginPairingRequest(bluetoothState: CBManagerState) {
        guard canStart else {
            pairingStatus = "Stop the current connection before searching for a camera."
            return
        }
        manualStopRequested = false
        prepareForNewSession(resetCounters: true)
        clearPairingCandidates()
        discoveredCameraName = nil
        connectionIntent = .pairing
        attemptOrigin = .foreground
        activeSessionRequested = true
        setUserLinkIntent(active: false)
        foregroundTimeoutSession.begin()
        switch bluetoothState {
        case .poweredOn:
            scanForPairingCameras()
        case .unknown, .resetting, .poweredOff:
            resumeWhenBluetoothPowersOn = true
            state = .bluetoothUnavailable
            pairingStatus = "Waiting for Bluetooth. Allow access or turn it on in iPhone Settings."
            startConnectionStageTimeout(.bluetooth)
        case .unauthorized, .unsupported:
            fail(CameraBluetoothAvailability(bluetoothState).guidance)
        @unknown default:
            fail("Bluetooth is unavailable on this device.")
        }
    }

    func handlePairingBluetoothUnavailable(_ bluetoothState: CBManagerState) {
        state = .bluetoothUnavailable
        if resumeWhenBluetoothPowersOn,
            [.unknown, .resetting, .poweredOff].contains(bluetoothState)
        {
            // Preserve the original bounded wait; state callbacks must not extend it.
            return
        }
        guard activeSessionRequested else { return }
        resumeWhenBluetoothPowersOn = false
        clearPairingCandidates()
        stopOperationTimeout()
        pendingOperation = nil
        onQueueEmpty = nil
        // CoreBluetooth invalidates the session when Bluetooth becomes unavailable.
        peripheral = nil
        characteristics.removeAll()
        pairingConfirmationPending = false
        experimentalApprovalPending = false
        fail(CameraBluetoothAvailability(bluetoothState).guidance)
    }

    func scanForPairingCameras() {
        guard activeSessionRequested, !manualStopRequested, connectionIntent == .pairing else { return }
        resumeWhenBluetoothPowersOn = false
        pairingStatus = "Searching for Sony cameras. Select your camera below."
        scanForCamera()
    }

    func addPairingCandidate(_ candidate: PairingCamera, peripheral: CBPeripheral) {
        pairingPeripherals[candidate.id] = peripheral
        if let index = pairingCameras.firstIndex(where: { $0.id == candidate.id }) {
            pairingCameras[index] = candidate
        } else {
            pairingCameras.append(candidate)
        }
    }

    func selectPairingCamera(id: UUID) {
        guard connectionIntent == .pairing, !manualStopRequested,
            state == .scanning || state == .idle,
            centralManager.state == .poweredOn,
            self.peripheral == nil,
            let candidate = pairingCameras.first(where: { $0.id == id }),
            let selected = pairingPeripherals[id]
        else { return }
        centralManager.stopScan()
        clearPairingCandidates()
        activeSessionRequested = true
        attemptOrigin = .foreground
        foregroundTimeoutSession.begin()
        discoveredCameraName = candidate.name
        advertisementProtocolVersion = candidate.protocolVersion
        peripheral = selected
        selected.delegate = self
        state = .connecting
        pairingStatus =
            "Accept any Bluetooth pairing request on your iPhone and camera. Keep the camera pairing screen open."
        startConnectionStageTimeout(.connecting)
        centralManager.connect(selected, options: connectOptions)
    }

    func finishPairingSearch() {
        centralManager.stopScan()
        cancelConnectionStageTimeout()
        activeSessionRequested = false
        attemptOrigin = .none
        if pairingCameras.isEmpty {
            fail("No Sony cameras found. Enable camera Bluetooth, open its pairing screen, and search again.")
        } else {
            state = .idle
            pairingStatus = "Search finished. Select a camera or search again."
        }
    }

    func presentPairingConfirmation() {
        guard connectionIntent == .pairing,
            activeSessionRequested, !manualStopRequested,
            didCompleteIdentityDiscovery,
            releaseAuthorization != nil,
            descriptor(SonyProtocol.pairingInitUUID)?.properties.contains(.write) == true
        else {
            fail("EE01 write-with-response is unavailable or this camera is not authorized for pairing.")
            return
        }
        cancelConnectionStageTimeout()
        pairingConfirmationPending = true
        pairingStatus =
            "Confirm that \(currentIdentity?.normalizedModel ?? "the camera") is on its Bluetooth pairing screen."
        state = .pairing
    }

    func confirmPairingInitialization() {
        guard connectionIntent == .pairing,
            activeSessionRequested, !manualStopRequested,
            pairingConfirmationPending, !experimentalApprovalPending,
            let authorization = releaseAuthorization,
            !authorization.requiresExperimentalApproval || sessionApprovalKey == expectedApprovalKey,
            currentIdentity != nil
        else { return }
        pairingConfirmationPending = false
        pairingStatus = "Accept the pairing request on your iPhone and camera. Waiting for the camera to confirm."
        state = .pairing
        enqueueWrite(
            name: "EE01 pairing init",
            uuid: SonyProtocol.pairingInitUUID,
            data: SonyProtocol.pairingInitPayload,
            required: true
        )
        onQueueEmpty = { [weak self] in self?.completePairingInitialization() }
        runNextOperationIfNeeded()
    }

    func completePairingInitialization() {
        pairingCompleted = true
        pairingStatus =
            "Camera accepted pairing initialization. Enable Location Info. Link on the camera, then start geotagging."
        attemptOrigin = .none
        activeSessionRequested = false
        state = .stopped
        if let peripheral {
            remember(peripheral: peripheral)
            centralManager.cancelPeripheralConnection(peripheral)
        }
    }

    func cancelPairingInitialization() {
        guard connectionIntent == .pairing else { return }
        pairingConfirmationPending = false
        pairingStatus = pairingCompleted ? pairingStatus : "Pairing cancelled."
        // Pairing never acquires DD controls. Disconnect immediately rather than waiting
        // up to a minute for an OS pairing prompt or an outstanding read/write callback.
        stopOperationTimeout()
        pendingOperation = nil
        operationQueue.removeAll()
        onQueueEmpty = nil
        cancelCurrentAttempt()
    }
}
