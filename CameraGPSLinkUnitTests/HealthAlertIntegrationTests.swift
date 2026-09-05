import CoreLocation
import XCTest

@testable import CameraGPSLink

final class HealthAlertSettingsTests: XCTestCase {
    func testMissingKeyDefaultsOffAndRoundTripPreservesUnknownValues() throws {
        let suite = "HealthAlertSettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("Could not create defaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("keep", forKey: "futureSetting")
        let store = UserDefaultsLinkSettingsStore(defaults: defaults)

        XCTAssertFalse(try store.load().healthAlertsEnabled)
        try store.save(
            LinkSettings(
                connectionAvailability: .whileAppIsOpen,
                locationUpdates: .batterySaver,
                healthAlertsEnabled: true
            )
        )

        XCTAssertTrue(try store.load().healthAlertsEnabled)
        XCTAssertEqual(defaults.string(forKey: "futureSetting"), "keep")
    }
}

@MainActor
final class HealthAlertAppModelTests: XCTestCase {
    func testEnablingAlertsRequestsAuthorizationOnlyAfterSuccessfulApply() {
        let notifications = RecordingHealthNotificationService(authorizationStatus: .notDetermined)
        let store = HealthTestSettingsStore(settings: .default)
        let model = makeModel(settingsStore: store, notifications: notifications)

        XCTAssertEqual(notifications.authorizationRequests, 0)
        var enabled = LinkSettings.default
        enabled.healthAlertsEnabled = true
        XCTAssertTrue(model.applySettings(enabled))

        XCTAssertEqual(notifications.authorizationRequests, 1)
        XCTAssertTrue(model.settings.healthAlertsEnabled)
    }

    func testDeniedPreferenceStaysEnabledAndErrorDoesNotReplaceConnectionState() {
        let notifications = RecordingHealthNotificationService(authorizationStatus: .denied)
        var settings = LinkSettings.default
        settings.healthAlertsEnabled = true
        let model = makeModel(
            settingsStore: HealthTestSettingsStore(settings: settings),
            notifications: notifications
        )
        let phase = model.viewState.phase

        notifications.sendError("Health alert scheduling failed: expected")

        XCTAssertTrue(model.settings.healthAlertsEnabled)
        XCTAssertEqual(model.notificationAuthorization, .denied)
        XCTAssertEqual(model.viewState.phase, phase)
        XCTAssertTrue(model.diagnosticsStore.copyText.contains("Health alert scheduling failed"))
    }

    func testEnabledUndeterminedAlertsCanRetryAuthorizationAfterInitialFailure() {
        let notifications = RecordingHealthNotificationService(authorizationStatus: .notDetermined)
        var settings = LinkSettings.default
        settings.healthAlertsEnabled = true
        let model = makeModel(
            settingsStore: HealthTestSettingsStore(settings: settings),
            notifications: notifications
        )

        XCTAssertEqual(notifications.authorizationRequests, 0)
        model.requestHealthAlertAuthorization()

        XCTAssertEqual(notifications.authorizationRequests, 1)
        notifications.setAuthorization(.denied)
        model.requestHealthAlertAuthorization()
        XCTAssertEqual(notifications.authorizationRequests, 1)
    }

    func testFailedSettingsSaveDoesNotRequestAuthorization() {
        let notifications = RecordingHealthNotificationService(authorizationStatus: .notDetermined)
        let store = HealthTestSettingsStore(settings: .default)
        store.saveError = HealthTestError.expected
        let model = makeModel(settingsStore: store, notifications: notifications)
        var enabled = LinkSettings.default
        enabled.healthAlertsEnabled = true

        XCTAssertFalse(model.applySettings(enabled))
        XCTAssertEqual(notifications.authorizationRequests, 0)
        XCTAssertFalse(model.settings.healthAlertsEnabled)
    }

    func testActiveLifecycleRefreshesNotificationAuthorization() {
        let notifications = RecordingHealthNotificationService(authorizationStatus: .allowed)
        let model = makeModel(
            settingsStore: HealthTestSettingsStore(settings: .default),
            notifications: notifications
        )
        let initialRefreshes = notifications.refreshes

        model.handleScenePhase(.active)

        XCTAssertEqual(notifications.refreshes, initialRefreshes + 1)
    }

    func testForegroundOnlyBackgroundTransitionSchedulesSuspensionButInactiveDoesNot() {
        let notifications = RecordingHealthNotificationService(authorizationStatus: .allowed)
        var settings = LinkSettings.default
        settings.healthAlertsEnabled = true
        let camera = HealthTestCameraService()
        camera.snapshot.state = .linked
        camera.snapshot.packetsSent = 1
        camera.snapshot.lastSentAt = Date(timeIntervalSince1970: 10_000)
        camera.snapshot.activeLinkIntent = true
        let model = makeModel(
            camera: camera,
            settingsStore: HealthTestSettingsStore(settings: settings),
            notifications: notifications
        )

        model.handleScenePhase(.inactive)
        XCTAssertFalse(notifications.scheduled.contains(where: { $0.kind == .foregroundSuspension }))
        model.handleScenePhase(.background)

        XCTAssertEqual(notifications.scheduled.filter { $0.kind == .foregroundSuspension }.count, 1)
    }

    func testAuthorizationChangesCancelAndRescheduleCurrentStaleDeadline() {
        let notifications = RecordingHealthNotificationService(authorizationStatus: .allowed)
        var settings = LinkSettings.default
        settings.healthAlertsEnabled = true
        let camera = HealthTestCameraService()
        camera.snapshot.state = .linked
        camera.snapshot.packetsSent = 1
        camera.snapshot.lastSentAt = Date(timeIntervalSince1970: 10_000)
        camera.snapshot.activeLinkIntent = true
        let model = makeModel(
            camera: camera,
            settingsStore: HealthTestSettingsStore(settings: settings),
            notifications: notifications
        )
        let originalSchedules = notifications.scheduled.count

        notifications.setAuthorization(.denied)
        XCTAssertEqual(model.notificationAuthorization, .denied)
        notifications.setAuthorization(.allowed)

        XCTAssertEqual(notifications.scheduled.count, originalSchedules + 1)
        XCTAssertEqual(notifications.scheduled.last?.kind, .staleCameraUpdate)
    }

    private func makeModel(
        camera: HealthTestCameraService? = nil,
        settingsStore: HealthTestSettingsStore,
        notifications: RecordingHealthNotificationService
    ) -> CameraGPSLinkAppModel {
        CameraGPSLinkAppModel(
            cameraService: camera ?? HealthTestCameraService(),
            locationService: HealthTestLocationService(),
            settingsStore: settingsStore,
            diagnosticsStore: DiagnosticsLogStore(),
            notificationService: notifications,
            now: { Date(timeIntervalSince1970: 10_000) },
            openSettings: {}
        )
    }
}

@MainActor
final class RecordingHealthNotificationService: HealthNotificationServicing {
    private(set) var authorizationStatus: HealthNotificationAuthorization
    var onAuthorizationChange: ((HealthNotificationAuthorization) -> Void)?
    var onError: ((HealthNotificationRequest?, String) -> Void)?
    var authorizationRequests = 0
    var refreshes = 0
    var scheduled: [HealthNotificationRequest] = []
    var removed: [Set<HealthNotificationKind>] = []
    var legacyRecoveryRemovalCount = 0
    var removeAllCount = 0

    init(authorizationStatus: HealthNotificationAuthorization) {
        self.authorizationStatus = authorizationStatus
    }

    func refreshAuthorization() { refreshes += 1 }
    func requestAuthorization() { authorizationRequests += 1 }
    func schedule(_ request: HealthNotificationRequest) { scheduled.append(request) }
    func remove(_ kinds: Set<HealthNotificationKind>) { removed.append(kinds) }
    func removeLegacyRecoveryNotification() { legacyRecoveryRemovalCount += 1 }
    func removeAllHealthNotifications() { removeAllCount += 1 }

    func setAuthorization(_ authorization: HealthNotificationAuthorization) {
        authorizationStatus = authorization
        onAuthorizationChange?(authorization)
    }

    func sendError(_ message: String, request: HealthNotificationRequest? = nil) {
        onError?(request, message)
    }
}

@MainActor
private final class HealthTestCameraService: CameraLinkServicing {
    var onChange: (() -> Void)?
    var snapshot = CameraServiceSnapshot(
        state: .idle,
        discoveredCameraName: nil,
        targetName: "Sony camera",
        packetsSent: 0,
        lastSentAt: nil,
        includeTimezone: true,
        dd21ConfigHex: nil,
        firmware: nil,
        protocolVersion: nil,
        profile: nil,
        confidence: .experimental,
        packetSize: nil,
        experimentalApprovalPending: false,
        pairingConfirmationPending: false,
        pairingStatus: "Not requested",
        cleanupDiagnostic: nil,
        operationOrder: [],
        lastError: nil,
        pendingReconnectArmed: false,
        activeLinkIntent: false,
        updateInterval: 120
    )

    func configure(settings: LinkSettings) {}
    func handleScenePhase(isForeground: Bool) {}
    func setLocationProvider(_ provider: @escaping () -> CLLocation?) {}
    func startForegroundLink() {}
    func resumeBackgroundLink() {}
    func cancelCurrentAttempt() {}
    func approveExperimentalProfile() {}
    func requestPairingInitialization() {}
    func selectPairingCamera(id: UUID) {}
    func confirmPairingInitialization() {}
    func cancelPairingInitialization() {}
    func stopLink() {}
    func sendLocationNow() {}
    func sendLocationIfDue() {}
}

@MainActor
private final class HealthTestLocationService: LocationServicing {
    var onChange: (() -> Void)?
    var snapshot = LocationServiceSnapshot(
        permission: .whenInUse,
        currentLocation: CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            altitude: 0,
            horizontalAccuracy: 8,
            verticalAccuracy: 8,
            timestamp: Date(timeIntervalSince1970: 10_000)
        ),
        isUpdating: true,
        lastError: nil
    )

    func configure(settings: LinkSettings, isForeground: Bool) {}
    func requestWhenInUseAuthorization() {}
    func requestAlwaysAuthorization() {}
    func startUpdating() {}
    func stopUpdating() {}
}

private enum HealthTestError: Error {
    case expected
}

private final class HealthTestSettingsStore: LinkSettingsStoring {
    var settings: LinkSettings
    var saveError: Error?

    init(settings: LinkSettings) {
        self.settings = settings
    }

    func load() throws -> LinkSettings { settings }

    func save(_ settings: LinkSettings) throws {
        if let saveError { throw saveError }
        self.settings = settings
    }
}
