import CoreBluetooth
import CoreLocation
import XCTest

@testable import CameraGPSLink

@MainActor
final class CameraPairingTests: XCTestCase {
    private let sonyAdvertisement = Data([0x2D, 0x01, 0x03, 0x00, 0x65, 0x00])

    func testDiscoveryRequiresSonyCameraManufacturerDataAndConnectability() throws {
        let id = UUID()
        let camera = try XCTUnwrap(
            PairingCamera.discovered(
                id: id, name: "ILCE-7CM2", manufacturerData: sonyAdvertisement, rssi: -45, isConnectable: true
            ))
        XCTAssertEqual(camera.id, id)
        XCTAssertEqual(camera.name, "ILCE-7CM2")
        XCTAssertEqual(camera.protocolVersion, 101)
        XCTAssertEqual(camera.rssi, -45)
        let invalidData: [Data?] = [
            nil, Data(), Data([0x4C, 0x00, 0x03, 0x00, 0x65, 0]),
            Data([0x2D, 0x01, 0x01, 0x00, 0x65, 0]), Data([0x03, 0x00, 0x65, 0]),
        ]
        for data in invalidData {
            XCTAssertNil(
                PairingCamera.discovered(
                    id: id, name: "ILCE-7CM2", manufacturerData: data, rssi: -45, isConnectable: true
                ))
        }
        XCTAssertNil(
            PairingCamera.discovered(
                id: id, name: "ILCE-7CM2", manufacturerData: sonyAdvertisement, rssi: -45, isConnectable: false
            ))
        XCTAssertEqual(
            PairingCamera.discovered(
                id: id, name: nil, manufacturerData: sonyAdvertisement, rssi: -45, isConnectable: true
            )?.name, "Sony camera")
    }

    func testInitialBluetoothWaitPreservesForegroundIntentAndDoesNotRequireLocation() {
        for state in [CBManagerState.unknown, .resetting, .poweredOff] {
            let scheduler = PairingTestScheduler()
            let manager = makeManager(scheduler: scheduler)
            manager.beginPairingRequest(bluetoothState: state)

            XCTAssertNil(manager.locationProvider)
            XCTAssertEqual(manager.connectionIntent, .pairing)
            XCTAssertEqual(manager.attemptOrigin, .foreground)
            XCTAssertTrue(manager.resumeWhenBluetoothPowersOn)
            XCTAssertTrue(manager.activeSessionRequested)
            XCTAssertFalse(manager.userLinkIntentActive)
            XCTAssertFalse(manager.canStart)
            XCTAssertEqual(manager.state, .bluetoothUnavailable)
            XCTAssertEqual(scheduler.delays, [60])
            XCTAssertTrue(manager.sanitizedOperationOrder.isEmpty)

            manager.handleBluetoothState(.poweredOff)
            manager.handleBluetoothState(.resetting)
            XCTAssertEqual(scheduler.delays, [60], "State callbacks must not extend the original deadline")
            manager.cancelPairingInitialization()
            XCTAssertFalse(manager.resumeWhenBluetoothPowersOn)
            XCTAssertFalse(manager.activeSessionRequested)
            XCTAssertTrue(manager.canStart)
            XCTAssertTrue(scheduler.tokens.allSatisfy(\.cancelled))
            manager.handleBluetoothState(.poweredOn)
            XCTAssertEqual(manager.state, .stopped, "Cancelled authorization must not restart a scan")
        }
    }

    func testPoweredOnResumesPairingScanWithoutLocationProviderOrRememberedReconnect() {
        let manager = makeManager()
        manager.beginPairingRequest(bluetoothState: .unknown)
        manager.handleBluetoothState(.poweredOn)
        XCTAssertEqual(manager.state, .scanning)
        XCTAssertEqual(manager.connectionIntent, .pairing)
        XCTAssertFalse(manager.resumeWhenBluetoothPowersOn)
        XCTAssertFalse(manager.pendingReconnectArmed)
        XCTAssertNil(manager.peripheral)
        XCTAssertNil(manager.locationProvider)
        XCTAssertTrue(manager.sanitizedOperationOrder.isEmpty)
        manager.cancelPairingInitialization()
    }

    func testDeniedAndUnsupportedBluetoothFailWithoutLeavingPendingWork() {
        for state in [CBManagerState.unauthorized, .unsupported] {
            let manager = makeManager()
            manager.beginPairingRequest(bluetoothState: state)
            XCTAssertEqual(manager.state, .failed)
            XCTAssertFalse(manager.resumeWhenBluetoothPowersOn)
            XCTAssertFalse(manager.activeSessionRequested)
            XCTAssertTrue(manager.canStart)
            XCTAssertEqual(manager.lastError, CameraBluetoothAvailability(state).guidance)
            XCTAssertTrue(manager.sanitizedOperationOrder.isEmpty)
        }
    }

    func testBluetoothWaitTimeoutDoesNotBecomeBackgroundRetry() {
        let scheduler = PairingTestScheduler()
        let manager = makeManager(scheduler: scheduler)
        manager.backgroundLinkEnabled = true
        manager.beginPairingRequest(bluetoothState: .unknown)
        scheduler.tokens.last?.action()
        XCTAssertEqual(manager.state, .failed)
        XCTAssertFalse(manager.resumeWhenBluetoothPowersOn)
        XCTAssertFalse(manager.pendingReconnectArmed)
        XCTAssertNil(manager.reconnectRetryTimer)
        XCTAssertFalse(manager.userLinkIntentActive)
        XCTAssertTrue(manager.canStart)
        XCTAssertTrue(manager.lastError?.contains("Bluetooth readiness timed out") == true)
    }

    func testSearchTimeoutRetainsChoicesButNeverConnectsOrWritesAutomatically() {
        let manager = makeManager()
        manager.connectionIntent = .pairing
        manager.state = .scanning
        manager.activeSessionRequested = true
        let camera = PairingCamera(id: UUID(), name: "ILCE-7CM2", rssi: -45, protocolVersion: 101)
        manager.pairingCameras = [camera]
        manager.handleConnectionStageTimeout(stage: .scanning)
        XCTAssertEqual(manager.state, .idle)
        XCTAssertEqual(manager.pairingCameras, [camera])
        XCTAssertNil(manager.peripheral)
        XCTAssertFalse(manager.activeSessionRequested)
        XCTAssertTrue(manager.canStart)
        XCTAssertTrue(manager.sanitizedOperationOrder.isEmpty)
        manager.cancelPairingInitialization()
        XCTAssertTrue(manager.pairingCameras.isEmpty)
    }

    func testEmptySearchTimeoutIsRetryable() {
        let manager = makeManager()
        manager.connectionIntent = .pairing
        manager.handleConnectionStageTimeout(stage: .scanning)
        XCTAssertEqual(manager.state, .failed)
        XCTAssertTrue(manager.canStart)
        XCTAssertTrue(manager.lastError?.contains("No Sony cameras found") == true)
    }

    func testPairingIdentityAndWriteTimeoutsAllowUserConfirmationButRemainBounded() {
        let scheduler = PairingTestScheduler()
        let manager = makeManager(scheduler: scheduler)
        XCTAssertEqual(manager.currentOperationTimeout, 12)
        manager.connectionIntent = .pairing
        XCTAssertEqual(manager.currentOperationTimeout, 60)
        manager.foregroundTimeoutSession.begin()
        manager.startConnectionStageTimeout(.discovering)
        XCTAssertEqual(scheduler.delays, [120])
        manager.cancelPairingInitialization()
    }

    func testPairingSkipsDD21ButRequiresExplicitExperimentalAndPairingApproval() {
        let manager = makeCandidateManager()
        manager.resolveDiscoveredProfile()
        XCTAssertEqual(manager.state, .awaitingApproval)
        XCTAssertTrue(manager.experimentalApprovalPending)
        XCTAssertFalse(manager.pairingConfirmationPending)
        XCTAssertTrue(manager.sanitizedOperationOrder.isEmpty)
        XCTAssertNil(manager.packetSize)

        manager.confirmPairingInitialization()
        XCTAssertTrue(manager.operationQueue.isEmpty)
        manager.approveExperimentalProfile()
        XCTAssertTrue(manager.pairingConfirmationPending)
        XCTAssertTrue(manager.sanitizedOperationOrder.isEmpty)

        // Hold the queue so the test can inspect explicit write scheduling without a BLE device.
        manager.pendingOperation = .read(name: "test barrier", uuid: "cc0b", required: false, onValue: nil)
        manager.confirmPairingInitialization()
        XCTAssertEqual(manager.operationQueue.map(\.name), ["EE01 pairing init"])
        manager.confirmPairingInitialization()
        XCTAssertEqual(manager.operationQueue.map(\.name), ["EE01 pairing init"], "Confirmation is one-shot")
        XCTAssertFalse(manager.pairingCompleted)
        manager.pendingOperation = nil
        manager.cancelPairingInitialization()
    }

    func testCancellationBeforeConfirmationNeverQueuesPairingOrLocationWrites() {
        let manager = makeCandidateManager()
        manager.resolveDiscoveredProfile()
        manager.approveExperimentalProfile()
        manager.cancelPairingInitialization()
        manager.confirmPairingInitialization()
        XCTAssertTrue(manager.operationQueue.isEmpty)
        XCTAssertTrue(manager.sanitizedOperationOrder.isEmpty)
        XCTAssertFalse(manager.pairingCompleted)
        XCTAssertEqual(manager.state, .stopped)
    }

    func testCancellationDuringPairingPromptClearsPendingOperationImmediately() {
        let manager = makeCandidateManager()
        manager.pendingOperation = .write(name: "EE01 pairing init", uuid: "ee01", required: true)
        manager.onQueueEmpty = { manager.completePairingInitialization() }
        manager.startOperationTimeout()
        manager.cancelPairingInitialization()
        XCTAssertNil(manager.pendingOperation)
        XCTAssertNil(manager.operationTimeoutTimer)
        XCTAssertNil(manager.onQueueEmpty)
        XCTAssertFalse(manager.cancelAfterCurrentOperation)
        XCTAssertFalse(manager.pairingCompleted)
        XCTAssertEqual(manager.state, .stopped)
        XCTAssertTrue(manager.canStart)
    }

    func testBluetoothLossClearsApprovalAndPendingPairingWork() {
        let manager = makeCandidateManager()
        manager.resolveDiscoveredProfile()
        manager.approveExperimentalProfile()
        manager.pendingOperation = .write(name: "EE01 pairing init", uuid: "ee01", required: true)
        manager.handleBluetoothState(.poweredOff)
        XCTAssertNil(manager.pendingOperation)
        XCTAssertFalse(manager.pairingConfirmationPending)
        XCTAssertFalse(manager.experimentalApprovalPending)
        XCTAssertFalse(manager.pairingCompleted)
        XCTAssertTrue(manager.operationQueue.isEmpty)
        XCTAssertEqual(manager.state, .failed)
        XCTAssertTrue(manager.canStart)
        manager.confirmPairingInitialization()
        XCTAssertTrue(manager.operationQueue.isEmpty)
    }

    func testAcknowledgedPairingWriteCompletesWithoutStartingLocationSession() {
        let manager = makeCandidateManager()
        manager.pendingOperation = .write(name: "EE01 pairing init", uuid: "ee01", required: true)
        manager.onQueueEmpty = { manager.completePairingInitialization() }
        manager.completeOperation(name: "EE01 pairing init", error: nil, required: true)
        XCTAssertTrue(manager.pairingCompleted)
        XCTAssertEqual(manager.state, .stopped)
        XCTAssertFalse(manager.activeSessionRequested)
        XCTAssertFalse(manager.didStartLocationSetup)
        XCTAssertEqual(manager.packetsSent, 0)
        XCTAssertTrue(manager.operationQueue.isEmpty)
    }

    func testFailedPairingWriteNeverReportsCompletion() {
        let manager = makeCandidateManager()
        manager.onQueueEmpty = { manager.completePairingInitialization() }
        manager.completeOperation(name: "EE01 pairing init", error: "Pairing rejected", required: true)
        XCTAssertFalse(manager.pairingCompleted)
        XCTAssertEqual(manager.state, .failed)
        XCTAssertTrue(manager.canStart)
        XCTAssertEqual(manager.pairingStatus, "Pairing rejected")
    }

    func testBackgroundingCancelsPairingEvenWhenBackgroundLocationIsConfigured() {
        let manager = makeManager()
        manager.backgroundLinkEnabled = true
        manager.beginPairingRequest(bluetoothState: .unknown)
        manager.handleScenePhase(isForeground: false)
        XCTAssertFalse(manager.resumeWhenBluetoothPowersOn)
        XCTAssertFalse(manager.activeSessionRequested)
        XCTAssertFalse(manager.userLinkIntentActive)
        XCTAssertEqual(manager.state, .stopped)
        manager.resumeBackgroundLink(locationProvider: { nil })
        XCTAssertEqual(manager.state, .stopped)
    }

    func testAppModelPairingDoesNotRequestLocationOrStartGeotagging() throws {
        let camera = PairingTestCameraService()
        let location = PairingTestLocationService()
        let model = CameraGPSLinkAppModel(
            cameraService: camera,
            locationService: location,
            settingsStore: PairingTestSettingsStore(),
            diagnosticsStore: DiagnosticsLogStore(),
            now: Date.init,
            openSettings: {}
        )
        model.requestPairingInitialization()
        let id = UUID()
        model.selectPairingCamera(id: id)
        model.confirmPairingInitialization()
        XCTAssertEqual(camera.calls, ["search", "select:\(id)", "confirm"])
        XCTAssertEqual(location.requests, 0)
        XCTAssertEqual(location.starts, 0)
        XCTAssertEqual(model.locationSnapshot.permission, .notDetermined)
        model.cancelPairingInitialization()
        XCTAssertEqual(camera.calls.last, "cancel")
    }

    private func makeManager(scheduler: PairingTestScheduler = PairingTestScheduler()) -> CameraBLEManager {
        CameraBLEManager(
            diagnosticsStore: DiagnosticsLogStore(),
            timeoutPolicy: ForegroundConnectionTimeoutPolicy(),
            timeoutScheduler: scheduler.scheduler,
            releasePolicy: SonyReleasePolicy(mode: .development)
        )
    }

    private func makeCandidateManager() -> CameraBLEManager {
        let manager = makeManager()
        manager.connectionIntent = .pairing
        manager.activeSessionRequested = true
        manager.discoveredCameraName = "ILCE-7CM2"
        manager.detectedFirmware = "2.01"
        manager.advertisementProtocolVersion = 101
        manager.descriptors = [
            SonyGattDescriptor(
                serviceUUID: SonyProtocol.locationServiceUUID,
                characteristicUUID: SonyProtocol.locationDataWriteUUID, properties: [.write]),
            SonyGattDescriptor(
                serviceUUID: SonyProtocol.locationServiceUUID,
                characteristicUUID: SonyProtocol.locationConfigReadUUID, properties: [.read]),
            SonyGattDescriptor(
                serviceUUID: SonyProtocol.locationServiceUUID,
                characteristicUUID: SonyProtocol.locationLockUUID, properties: [.read, .write]),
            SonyGattDescriptor(
                serviceUUID: SonyProtocol.locationServiceUUID,
                characteristicUUID: SonyProtocol.locationEnableUUID, properties: [.read, .write]),
            SonyGattDescriptor(
                serviceUUID: SonyProtocol.pairingServiceUUID,
                characteristicUUID: SonyProtocol.pairingInitUUID, properties: [.write]),
        ]
        return manager
    }
}

private final class PairingTestScheduler {
    var delays: [TimeInterval] = []
    var tokens: [Token] = []
    var scheduler: ConnectionTimeoutScheduler {
        ConnectionTimeoutScheduler { delay, action in
            self.delays.append(delay)
            let token = Token(action: action)
            self.tokens.append(token)
            return token
        }
    }
    final class Token: ConnectionTimeoutCancellable {
        let action: () -> Void
        var cancelled = false
        init(action: @escaping () -> Void) { self.action = action }
        func cancel() { cancelled = true }
    }
}

@MainActor
private final class PairingTestCameraService: CameraLinkServicing {
    var onChange: (() -> Void)?
    var snapshot = CameraServiceSnapshot(
        state: .idle, targetName: "Sony camera", packetsSent: 0, includeTimezone: true,
        confidence: .experimental, experimentalApprovalPending: false, pairingConfirmationPending: false,
        pairingStatus: "Not requested", operationOrder: [], pendingReconnectArmed: false,
        activeLinkIntent: false, updateInterval: 30
    )
    var calls: [String] = []
    func configure(settings: LinkSettings) {}
    func handleScenePhase(isForeground: Bool) {}
    func setLocationProvider(_ provider: @escaping () -> CLLocation?) {}
    func startForegroundLink() { calls.append("location") }
    func resumeBackgroundLink() { calls.append("background") }
    func cancelCurrentAttempt() {}
    func approveExperimentalProfile() {}
    func requestPairingInitialization() { calls.append("search") }
    func selectPairingCamera(id: UUID) { calls.append("select:\(id)") }
    func confirmPairingInitialization() { calls.append("confirm") }
    func cancelPairingInitialization() { calls.append("cancel") }
    func stopLink() {}
    func sendLocationNow() { calls.append("send") }
    func sendLocationIfDue() {}
}

@MainActor
private final class PairingTestLocationService: LocationServicing {
    var onChange: (() -> Void)?
    var snapshot = LocationServiceSnapshot(permission: .notDetermined, isUpdating: false)
    var requests = 0
    var starts = 0
    func configure(settings: LinkSettings, isForeground: Bool) {}
    func requestWhenInUseAuthorization() { requests += 1 }
    func requestAlwaysAuthorization() { requests += 1 }
    func startUpdating() { starts += 1 }
    func stopUpdating() {}
}

private final class PairingTestSettingsStore: LinkSettingsStoring {
    func load() throws -> LinkSettings { .default }
    func save(_ settings: LinkSettings) throws {}
}
