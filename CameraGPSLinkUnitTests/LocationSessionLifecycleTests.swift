import CoreLocation
import XCTest

@testable import CameraGPSLink

// Transition contract (intent is owned by BLE, location lifetime by the app model):
// Event                              BLE state               Intent   Location
// Foreground failure/timeout         failed                  false    stop
// Unsupported identity               unsupported             false    stop
// Cleanup after terminal failure     stopping/failed         false    stop
// Foreground Bluetooth unavailable   bluetoothUnavailable    false    stop
// Background Bluetooth wait/retry    unavailable/connecting  true     retain
// Candidate rejection/rescan         scanning                true     retain
// Explicit Stop/Cancel               stopping/stopped        false    stop, suppress alerts
// Fresh explicit Start               scanning                true     restart
// Baseline: terminal snapshots with false intent cleared the request but left GPS on.
@MainActor
final class LocationSessionLifecycleTests: XCTestCase {
    func testTerminalSnapshotsStopLocationIdempotently() {
        for state in [CameraConnectionState.failed, .unsupported, .stopped, .stopping, .bluetoothUnavailable] {
            let context = Context()
            context.model.startGeotagging()
            XCTAssertTrue(context.location.snapshot.isUpdating)

            context.camera.transition(to: state, intent: false)
            context.camera.onChange?()
            context.location.onChange?()

            XCTAssertFalse(context.location.snapshot.isUpdating, "state: \(state)")
            XCTAssertEqual(context.location.stops, 1, "state: \(state)")
        }
    }

    func testTerminalFailureDoesNotResumeOnLaterSceneChanges() {
        let context = Context(background: true)
        context.model.startGeotagging()
        context.camera.transition(to: .failed, intent: false)

        context.model.handleScenePhase(.background)
        context.model.handleScenePhase(.active)

        XCTAssertEqual(context.camera.resumes, 0)
        XCTAssertFalse(context.location.snapshot.isUpdating)
    }

    func testBackgroundWaitingAndCandidateRescanRetainLocation() {
        let context = Context(background: true)
        context.model.startGeotagging()
        for state in [CameraConnectionState.connecting, .scanning, .bluetoothUnavailable] {
            context.camera.transition(to: state, intent: true)
            XCTAssertTrue(context.location.snapshot.isUpdating, "state: \(state)")
        }
        context.model.handleScenePhase(.background)
        XCTAssertEqual(context.camera.resumes, 1)
        XCTAssertEqual(context.location.stops, 0)
    }

    func testExplicitRestartSurvivesSynchronousLocationPublication() {
        let context = Context()
        context.model.startGeotagging()
        context.camera.transition(to: .failed, intent: false)
        context.model.retry()

        XCTAssertEqual(context.camera.starts, 2)
        XCTAssertEqual(context.location.starts, 2)
        XCTAssertEqual(context.location.stops, 1)
        XCTAssertTrue(context.location.snapshot.isUpdating)
        XCTAssertEqual(context.model.viewState.phase, .searching)
    }

    func testSynchronousBluetoothFailureStopsNewlyStartedLocation() {
        let context = Context()
        context.camera.startState = .bluetoothUnavailable
        context.model.startGeotagging()

        XCTAssertFalse(context.location.snapshot.isUpdating)
        XCTAssertEqual(context.location.stops, 1)
    }

    func testIncompleteCleanupStillWarnsAfterPreviouslyReadySession() {
        let context = Context(alerts: true)
        context.model.startGeotagging()
        context.camera.snapshot.packetsSent = 1
        context.camera.snapshot.lastSentAt = context.now
        context.camera.transition(to: .linked, intent: true)
        let removalsBeforeFailure = context.notifications.removeAllCount
        context.camera.snapshot.cleanupDiagnostic = "Incomplete cleanup: fixture"
        context.camera.transition(to: .stopping, intent: false)
        context.camera.transition(to: .failed, intent: false)

        XCTAssertFalse(context.location.snapshot.isUpdating)
        XCTAssertEqual(context.location.stops, 1)
        XCTAssertEqual(context.notifications.removeAllCount, removalsBeforeFailure)
        XCTAssertEqual(context.notifications.scheduled.filter { $0.kind == .linkLoss }.count, 1)
    }

    func testInitialFailureDoesNotScheduleLossAlert() {
        let context = Context(alerts: true)
        context.model.startGeotagging()
        context.camera.transition(to: .failed, intent: false)
        XCTAssertFalse(context.notifications.scheduled.contains { $0.kind == .linkLoss })
        XCTAssertFalse(context.location.snapshot.isUpdating)
    }

    func testExplicitStopAndCancelSuppressLossAndRestart() {
        for action in [GeotaggingAction.stop, .cancel] {
            let context = Context(alerts: true)
            context.model.startGeotagging()
            context.camera.snapshot.packetsSent = 1
            context.camera.snapshot.lastSentAt = context.now
            context.camera.transition(to: .linked, intent: true)
            let sendsBeforeStop = context.camera.dueSends
            context.model.perform(action)
            XCTAssertEqual(context.camera.dueSends, sendsBeforeStop)
            XCTAssertFalse(context.location.snapshot.isUpdating)
            XCTAssertEqual(context.location.stops, 1)
            XCTAssertFalse(context.notifications.scheduled.contains { $0.kind == .linkLoss })
            context.model.startGeotagging()
            XCTAssertTrue(context.location.snapshot.isUpdating)
        }
    }

    func testCancelledPermissionIntentCannotStartLater() {
        let context = Context(permission: .notDetermined)
        context.model.startGeotagging()
        context.model.cancelCurrentAttempt()
        context.location.snapshot.permission = .whenInUse
        context.location.onChange?()
        XCTAssertEqual(context.camera.starts, 0)
        XCTAssertFalse(context.location.snapshot.isUpdating)
    }

    func testReadingDiagnosticSummaryDoesNotStartServicesOrRequestPermissions() {
        let context = Context(permission: .notDetermined)
        XCTAssertTrue(context.model.diagnosticSummary.contains("Last camera update: Not sent yet"))
        XCTAssertEqual(context.camera.starts, 0)
        XCTAssertEqual(context.location.starts, 0)
        XCTAssertEqual(context.location.permissionRequests, 0)
        XCTAssertEqual(context.notifications.authorizationRequests, 0)
    }

    func testPairingDoesNotStartLocationOrPermissionRequests() {
        let context = Context(permission: .notDetermined)
        context.model.requestPairingInitialization()
        XCTAssertEqual(context.camera.pairings, 1)
        XCTAssertEqual(context.location.starts, 0)
        XCTAssertEqual(context.location.permissionRequests, 0)
    }

    func testInactiveKeepsLocationButForegroundOnlyBackgroundStops() {
        let context = Context(alerts: true)
        context.model.startGeotagging()
        context.camera.snapshot.packetsSent = 1
        context.camera.snapshot.lastSentAt = context.now
        context.camera.transition(to: .linked, intent: true)
        context.model.handleScenePhase(.inactive)
        XCTAssertTrue(context.location.snapshot.isUpdating)
        let sendsBeforeBackground = context.camera.dueSends
        context.model.handleScenePhase(.background)
        XCTAssertFalse(context.location.snapshot.isUpdating)
        XCTAssertEqual(context.camera.dueSends, sendsBeforeBackground)
        XCTAssertEqual(context.notifications.scheduled.filter { $0.kind == .foregroundSuspension }.count, 1)
        XCTAssertFalse(context.notifications.scheduled.contains { $0.kind == .linkLoss })
    }

    @MainActor
    private final class Context {
        let now = Date(timeIntervalSince1970: 10_000)
        let camera = LifecycleCameraService()
        let location: LifecycleLocationService
        let notifications = RecordingHealthNotificationService(authorizationStatus: .allowed)
        let model: CameraGPSLinkAppModel

        init(background: Bool = false, alerts: Bool = false, permission: LocationPermission = .always) {
            location = LifecycleLocationService(permission: permission)
            model = CameraGPSLinkAppModel(
                cameraService: camera,
                locationService: location,
                settingsStore: LifecycleSettingsStore(
                    settings: LinkSettings(
                        connectionAvailability: background ? .continueInBackground : .whileAppIsOpen,
                        locationUpdates: .batterySaver,
                        healthAlertsEnabled: alerts
                    )),
                diagnosticsStore: DiagnosticsLogStore(),
                notificationService: notifications,
                now: { Date(timeIntervalSince1970: 10_000) },
                openSettings: {},
                releasePolicy: SonyReleasePolicy(mode: .development)
            )
        }
    }
}

@MainActor
private final class LifecycleCameraService: CameraLinkServicing {
    var onChange: (() -> Void)?
    var snapshot = CameraServiceSnapshot(
        state: .idle, discoveredCameraName: nil, targetName: "Sony camera", packetsSent: 0,
        lastSentAt: nil, includeTimezone: true, dd21ConfigHex: nil, firmware: nil,
        protocolVersion: nil, profile: nil, confidence: .experimental, packetSize: nil,
        experimentalApprovalPending: false, pairingConfirmationPending: false,
        pairingStatus: "Not requested", cleanupDiagnostic: nil, operationOrder: [], lastError: nil,
        pendingReconnectArmed: false, activeLinkIntent: false, updateInterval: 120
    )
    var starts = 0
    var resumes = 0
    var pairings = 0
    var dueSends = 0
    var startState: CameraConnectionState = .scanning
    private var backgroundEnabled = false

    func transition(to state: CameraConnectionState, intent: Bool) {
        snapshot.state = state
        snapshot.activeLinkIntent = intent
        snapshot.pendingReconnectArmed = intent && [.connecting, .bluetoothUnavailable].contains(state)
        onChange?()
    }

    func configure(settings: LinkSettings) { backgroundEnabled = settings.backgroundLinkEnabled }
    func handleScenePhase(isForeground: Bool) {
        if !isForeground, !backgroundEnabled { stopLink() }
    }
    func setLocationProvider(_ provider: @escaping () -> CLLocation?) {}
    func startForegroundLink() {
        starts += 1
        transition(to: startState, intent: startState == .scanning)
    }
    func resumeBackgroundLink() { resumes += 1 }
    func cancelCurrentAttempt() { stopLink() }
    func stopLink() { transition(to: .stopped, intent: false) }
    func approveExperimentalProfile() {}
    func requestPairingInitialization() {
        pairings += 1
        transition(to: .pairing, intent: false)
    }
    func selectPairingCamera(id: UUID) {}
    func confirmPairingInitialization() {}
    func cancelPairingInitialization() {}
    func sendLocationNow() {}
    func sendLocationIfDue() { dueSends += 1 }
}

@MainActor
private final class LifecycleLocationService: LocationServicing {
    var onChange: (() -> Void)?
    var snapshot: LocationServiceSnapshot
    var starts = 0
    var stops = 0
    var permissionRequests = 0

    init(permission: LocationPermission) {
        snapshot = LocationServiceSnapshot(
            permission: permission, currentLocation: nil, isUpdating: false, lastError: nil)
    }

    func configure(settings: LinkSettings, isForeground: Bool) { onChange?() }
    func requestWhenInUseAuthorization() { permissionRequests += 1 }
    func requestAlwaysAuthorization() { permissionRequests += 1 }
    func startUpdating() {
        starts += 1
        snapshot.isUpdating = true
        onChange?()
    }
    func stopUpdating() {
        stops += 1
        snapshot.isUpdating = false
        // Publish even on repeated calls, like the production @Published properties.
        onChange?()
    }
}

private struct LifecycleSettingsStore: LinkSettingsStoring {
    let settings: LinkSettings
    func load() throws -> LinkSettings { settings }
    func save(_ settings: LinkSettings) throws {}
}
