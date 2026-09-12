import CoreBluetooth
import XCTest

@testable import CameraGPSLink

@MainActor
final class CameraBLELifecycleTests: XCTestCase {
    private var previousIntent: Any?

    override func setUp() {
        super.setUp()
        previousIntent = UserDefaults.standard.object(forKey: CameraBLEDefaults.activeLinkIntent)
    }

    override func tearDown() {
        UserDefaults.standard.set(previousIntent, forKey: CameraBLEDefaults.activeLinkIntent)
        super.tearDown()
    }

    func testFailureEndsIntentAndDisarmsRetryWithoutPossiblyAppliedControls() {
        let manager = makeManager(origin: .foreground)
        manager.scheduleReconnectRetry(reason: "fixture")
        manager.fail("fixture failure")

        assertEnded(manager)
        XCTAssertEqual(manager.state, .failed)
        XCTAssertNil(manager.reconnectRetryTimer)
        manager.resumeBackgroundLink { nil }
        XCTAssertEqual(manager.state, .failed)
    }

    func testStageTimeoutEndsForegroundIntentEvenWithBackgroundConfigured() {
        let manager = makeManager(origin: .foreground)
        manager.handleConnectionStageTimeout(stage: .connecting)
        assertEnded(manager)
        XCTAssertEqual(manager.state, .failed)
    }

    func testPendingOperationFailureKeepsCleanupBarrierButEndsIntent() {
        let manager = makeManager(origin: .foreground)
        manager.pendingOperation = .write(name: "DD31 enable", uuid: "dd31", required: true)
        manager.fail("fixture failure")
        assertEnded(manager)
        XCTAssertTrue(manager.cancelAfterCurrentOperation)
        XCTAssertNotNil(manager.pendingOperation)
        manager.pendingOperation = nil
    }

    func testForegroundBluetoothLossEndsIntentWithoutStartingBackgroundRetry() {
        for state in [CBManagerState.poweredOff, .unauthorized, .unsupported, .resetting, .unknown] {
            let manager = makeManager(origin: .foreground)
            manager.handleBluetoothState(state)
            assertEnded(manager)
            XCTAssertEqual(manager.state, .bluetoothUnavailable)
            XCTAssertFalse(manager.resumeWhenBluetoothPowersOn)
        }
    }

    func testEligibleBackgroundBluetoothWaitRetainsIntent() {
        let manager = makeManager(origin: .background)
        manager.handleBluetoothState(.poweredOff)
        XCTAssertTrue(manager.userLinkIntentActive)
        XCTAssertTrue(manager.activeSessionRequested)
        XCTAssertTrue(manager.resumeWhenBluetoothPowersOn)
        XCTAssertEqual(manager.state, .bluetoothUnavailable)
        manager.stopLink()
    }

    func testPersistedIntentSurvivesTransientBluetoothStateBeforeRestoration() {
        let manager = makeManager(origin: .none)
        manager.activeSessionRequested = false
        manager.handleBluetoothState(.unknown)
        XCTAssertTrue(manager.userLinkIntentActive)
        XCTAssertTrue(manager.activeSessionRequested)
        XCTAssertTrue(manager.resumeWhenBluetoothPowersOn)
        XCTAssertEqual(manager.attemptOrigin, .background)
        manager.stopLink()
    }

    func testCancelledIntentDoesNotRearmWhenBluetoothChanges() {
        let manager = makeManager(origin: .background)
        manager.cancelCurrentAttempt()
        manager.handleBluetoothState(.poweredOff)
        assertEnded(manager)
        XCTAssertFalse(manager.resumeWhenBluetoothPowersOn)
    }

    func testRevokedBluetoothPermissionIsTerminalEvenForBackgroundAttempt() {
        let manager = makeManager(origin: .background)
        manager.handleBluetoothState(.unauthorized)
        assertEnded(manager)
        XCTAssertFalse(manager.resumeWhenBluetoothPowersOn)
    }

    func testBluetoothLossWithAcquiredControlsRemainsTerminal() {
        let manager = makeManager(origin: .background)
        manager.acquisition.recordAttempt(actionName: "DD30 lock")
        manager.handleBluetoothState(.poweredOff)
        assertEnded(manager)
        XCTAssertEqual(manager.state, .failed)
        XCTAssertTrue(manager.cleanupDiagnostic?.hasPrefix("Incomplete cleanup") == true)
    }

    private func makeManager(origin: CameraAttemptOrigin) -> CameraBLEManager {
        let manager = CameraBLEManager(
            diagnosticsStore: DiagnosticsLogStore(),
            timeoutPolicy: ForegroundConnectionTimeoutPolicy(),
            timeoutScheduler: .live,
            identityStore: LifecycleIdentityStore(),
            releasePolicy: SonyReleasePolicy(mode: .development)
        )
        manager.backgroundLinkEnabled = true
        manager.attemptOrigin = origin
        manager.activeSessionRequested = true
        manager.manualStopRequested = false
        manager.state = .connecting
        manager.setUserLinkIntent(active: true)
        return manager
    }

    private func assertEnded(_ manager: CameraBLEManager, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(manager.userLinkIntentActive, file: file, line: line)
        XCTAssertFalse(manager.activeSessionRequested, file: file, line: line)
        XCTAssertTrue(manager.manualStopRequested, file: file, line: line)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: CameraBLEDefaults.activeLinkIntent), file: file, line: line)
    }
}

private struct LifecycleIdentityStore: SonyValidatedIdentityStoring {
    func load() -> SonyValidatedIdentityRecord? { nil }
    func save(_ record: SonyValidatedIdentityRecord) {}
    func clear() {}
}
