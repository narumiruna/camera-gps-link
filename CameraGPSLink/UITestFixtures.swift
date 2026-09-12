#if DEBUG
    import CoreLocation
    import Foundation
    import SwiftUI

    /// Intercept external links in UI fixtures so tests never launch a browser.
    struct UITestURLHandling: ViewModifier {
        @State private var openedURL: URL?

        func body(content: Content) -> some View {
            if ProcessInfo.processInfo.environment["SONYGEOTAG_UI_SCENARIO"] != nil {
                content
                    .environment(
                        \.openURL,
                        OpenURLAction { url in
                            openedURL = url
                            return ProcessInfo.processInfo.environment["SONYGEOTAG_UI_DISCARD_URLS"] == "1"
                                ? .discarded : .handled
                        }
                    )
                    .overlay(alignment: .bottom) {
                        if let openedURL {
                            // Read the recorded destination after dismissing the settings sheet.
                            Text(openedURL.absoluteString)
                                .font(.caption)
                                .lineLimit(1)
                                .accessibilityIdentifier("ui-test-opened-url")
                        }
                    }
            } else {
                content
            }
        }
    }

    /// Apply test appearance explicitly; iOS can ignore the legacy launch-default overrides.
    struct UITestAppearance: ViewModifier {
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize

        func body(content: Content) -> some View {
            if ProcessInfo.processInfo.environment["SONYGEOTAG_UI_SCENARIO"] != nil {
                content
                    .preferredColorScheme(Self.colorScheme(for: argument("-AppleInterfaceStyle")))
                    .dynamicTypeSize(
                        argument("-UIPreferredContentSizeCategoryName")
                            == "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge"
                            ? .accessibility5 : dynamicTypeSize
                    )
            } else {
                content
            }
        }

        static func colorScheme(for interfaceStyle: String?) -> ColorScheme? {
            switch interfaceStyle {
            case "Light": .light
            case "Dark": .dark
            default: nil
            }
        }

        private func argument(_ name: String) -> String? {
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
    }

    @MainActor
    enum UITestAppModelFactory {
        static func makeFromEnvironment() -> CameraGPSLinkAppModel? {
            guard let scenario = ProcessInfo.processInfo.environment["SONYGEOTAG_UI_SCENARIO"] else {
                return nil
            }

            let now = Date(timeIntervalSince1970: 10_000)
            let diagnostics = DiagnosticsLogStore()
            if scenario != "empty-diagnostics" {
                diagnostics.append("8:00:00 PM  Bluetooth powered on")
                diagnostics.append("8:00:01 PM  DD11 location OK 35.6812360, 139.7671250")
            }

            var settings = LinkSettings.default
            var camera = CameraServiceSnapshot.fixture
            var permission: LocationPermission = .whenInUse
            var location: CLLocation?
            var persistenceFails = false
            var releasePolicy = SonyReleasePolicy.current
            var notificationAuthorization: HealthNotificationAuthorization = .allowed

            switch scenario {
            case "not-connected", "empty-diagnostics":
                break
            case "first-run":
                permission = .notDetermined
            case "pairing-first-run":
                permission = .notDetermined
                camera.pairing.bluetooth = .ready
            case "pairing-bluetooth-denied":
                permission = .notDetermined
                camera.pairing.bluetooth = .denied
            case "searching":
                camera.state = .scanning
            case "connecting":
                camera.state = .connecting
                camera.discoveredCameraName = "ILCE-7CM2"
            case "experimental-approval":
                camera.state = .awaitingApproval
                camera.discoveredCameraName = "ILCE-7M4"
                camera.targetName = "ILCE-7M4"
                camera.firmware = "4.00"
                camera.profile = .modern
                camera.confidence = .experimental
                camera.experimentalApprovalPending = true
                location = fixtureLocation(now: now)
            case "unsupported":
                camera.state = .unsupported
                camera.discoveredCameraName = "Unknown Sony camera"
                camera.profile = .unsupported
                camera.confidence = .unsupported
                camera.lastError = "DD11 lacks write-with-response."
            case "connected-before-send":
                camera.state = .linked
                location = fixtureLocation(now: now)
            case "waiting-for-location":
                camera.state = .linked
            case "ready":
                camera.state = .linked
                camera.packetsSent = 1
                camera.lastSentAt = now.addingTimeInterval(-12)
                camera.discoveredCameraName = "ILCE-7CM2"
                location = fixtureLocation(now: now)
            case "stopping":
                camera.state = .stopping
            case "stopped":
                camera.state = .stopped
            case "failed", "timeout":
                camera.state = .failed
                camera.lastError = "Camera connection timed out. Make sure the camera is nearby and ready."
            case "permission-denied":
                permission = .denied
            case "background-waiting":
                settings.connectionAvailability = .continueInBackground
                permission = .always
                camera.state = .connecting
                camera.pendingReconnectArmed = true
            case "background-partial":
                settings.connectionAvailability = .continueInBackground
                camera.state = .linked
                camera.packetsSent = 1
                camera.lastSentAt = now
                location = fixtureLocation(now: now)
            case "settings-failure":
                persistenceFails = true
            case "public-release-settings":
                releasePolicy = SonyReleasePolicy(mode: .publicRelease)
            case "public-release-experimental":
                releasePolicy = SonyReleasePolicy(mode: .publicRelease)
                camera.state = .awaitingApproval
                camera.discoveredCameraName = "ILCE-7M4"
                camera.targetName = "ILCE-7M4"
                camera.firmware = "4.00"
                camera.profile = .modern
                camera.confidence = .experimental
                camera.experimentalApprovalPending = true
                camera.lastError = "This camera identity is not supported by this public release."
                location = fixtureLocation(now: now)
            case "dense-diagnostics":
                for index in 0..<140 {
                    diagnostics.append("log \(index)")
                }
            case "health-alerts-allowed", "health-alerts-blocked", "health-alerts-not-determined",
                "health-alerts-foreground-suspension":
                settings.healthAlertsEnabled = true
                if scenario == "health-alerts-blocked" {
                    notificationAuthorization = .denied
                } else if scenario == "health-alerts-not-determined" {
                    notificationAuthorization = .notDetermined
                } else {
                    notificationAuthorization = .allowed
                }
                camera.state = .linked
                camera.packetsSent = 1
                camera.lastSentAt = now
                camera.activeLinkIntent = true
                location = fixtureLocation(now: now)
            case "stale-location", "low-accuracy", "future-location", "invalid-location", "missing-location",
                "coexisting-notices":
                settings.healthAlertsEnabled = true
                camera.state = .linked
                camera.packetsSent = 1
                camera.lastSentAt = now.addingTimeInterval(-12)
                camera.activeLinkIntent = true
                if scenario == "stale-location" || scenario == "coexisting-notices" {
                    location = fixtureLocation(now: now, age: 121)
                } else if scenario == "low-accuracy" {
                    location = fixtureLocation(now: now, accuracy: 101)
                } else if scenario == "future-location" {
                    location = fixtureLocation(now: now, age: -11)
                } else if scenario != "missing-location" {
                    location = fixtureLocation(now: now, accuracy: -1)
                }
                if scenario == "coexisting-notices" {
                    settings.connectionAvailability = .continueInBackground
                }
            case "stale-camera-update":
                settings.healthAlertsEnabled = true
                camera.state = .linked
                camera.packetsSent = 1
                camera.lastSentAt = now.addingTimeInterval(-301)
                camera.activeLinkIntent = true
                location = fixtureLocation(now: now)
            default:
                return nil
            }

            let cameraService = UITestCameraService(snapshot: camera, now: now)
            let locationService = UITestLocationService(
                snapshot: LocationServiceSnapshot(
                    permission: permission,
                    currentLocation: location,
                    isUpdating: location != nil,
                    lastError: nil,
                    updateModeLabel: location == nil ? "Stopped" : "High accuracy"
                )
            )
            let store = UITestSettingsStore(settings: settings, shouldFail: persistenceFails)
            let notificationService = UITestHealthNotificationService(
                authorizationStatus: notificationAuthorization
            )
            let model = CameraGPSLinkAppModel(
                cameraService: cameraService,
                locationService: locationService,
                settingsStore: store,
                diagnosticsStore: diagnostics,
                notificationService: notificationService,
                now: { now },
                openSettings: {},
                releasePolicy: releasePolicy
            )
            if scenario == "health-alerts-foreground-suspension" {
                model.handleScenePhase(.background)
            }
            return model
        }

        private static func fixtureLocation(
            now: Date,
            age: TimeInterval = 0,
            accuracy: CLLocationAccuracy = 8
        ) -> CLLocation {
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 35.681236, longitude: 139.767125),
                altitude: 10,
                horizontalAccuracy: accuracy,
                verticalAccuracy: 10,
                timestamp: now.addingTimeInterval(-age)
            )
        }
    }

    @MainActor
    private final class UITestCameraService: CameraLinkServicing {
        var onChange: (() -> Void)?
        var snapshot: CameraServiceSnapshot
        private let now: Date
        private var locationProvider: (() -> CLLocation?) = { nil }

        init(snapshot: CameraServiceSnapshot, now: Date) {
            self.snapshot = snapshot
            self.now = now
        }

        func configure(settings: LinkSettings) {
            snapshot.updateInterval = settings.lowPowerModeEnabled ? 120 : 30
        }

        func handleScenePhase(isForeground: Bool) {}

        func setLocationProvider(_ provider: @escaping () -> CLLocation?) {
            locationProvider = provider
        }

        func startForegroundLink() {
            snapshot.state = .scanning
            snapshot.lastError = nil
            onChange?()
        }

        func resumeBackgroundLink() {
            if snapshot.state == .idle || snapshot.state == .stopped {
                snapshot.state = .connecting
                snapshot.pendingReconnectArmed = true
                onChange?()
            }
        }

        func cancelCurrentAttempt() {
            snapshot.state = .stopped
            snapshot.pendingReconnectArmed = false
            onChange?()
        }

        func approveExperimentalProfile() {
            snapshot.experimentalApprovalPending = false
            snapshot.state = .enablingLocation
            onChange?()
        }

        func requestPairingInitialization() {
            snapshot.pairing.isPairing = true
            snapshot.pairing.completed = false
            if snapshot.pairing.bluetooth == .denied {
                snapshot.state = .failed
                snapshot.pairingStatus = snapshot.pairing.bluetooth.guidance
            } else {
                snapshot.state = .scanning
                snapshot.pairing.canSearch = false
                snapshot.pairingStatus = "Select your camera."
                snapshot.pairing.cameras = [
                    PairingCamera(id: UUID(), name: "ILCE-7CM2", rssi: -45, protocolVersion: 101),
                    PairingCamera(id: UUID(), name: "ILCE-7M4", rssi: -65, protocolVersion: 101),
                ]
            }
            onChange?()
        }

        func selectPairingCamera(id: UUID) {
            guard let candidate = snapshot.pairing.cameras.first(where: { $0.id == id }) else { return }
            snapshot.discoveredCameraName = candidate.name
            snapshot.pairing.cameras = []
            snapshot.pairingConfirmationPending = true
            snapshot.state = .pairing
            snapshot.pairingStatus = "Confirm that \(candidate.name) is on its pairing screen."
            onChange?()
        }

        func confirmPairingInitialization() {
            guard snapshot.pairingConfirmationPending else { return }
            snapshot.pairingConfirmationPending = false
            snapshot.pairingStatus = "Camera accepted pairing initialization."
            snapshot.pairing.completed = true
            snapshot.pairing.canSearch = true
            snapshot.state = .stopped
            onChange?()
        }

        func cancelPairingInitialization() {
            guard snapshot.pairing.isPairing else { return }
            snapshot.pairingConfirmationPending = false
            snapshot.pairing.cameras = []
            snapshot.pairing.canSearch = true
            snapshot.state = .stopped
            onChange?()
        }

        func stopLink() {
            snapshot.state = .stopped
            snapshot.pendingReconnectArmed = false
            onChange?()
        }

        func sendLocationNow() {
            guard snapshot.state == .linked, locationProvider() != nil else { return }
            snapshot.packetsSent += 1
            snapshot.lastSentAt = now
            onChange?()
        }

        func sendLocationIfDue() {}
    }

    @MainActor
    private final class UITestLocationService: LocationServicing {
        var onChange: (() -> Void)?
        var snapshot: LocationServiceSnapshot

        init(snapshot: LocationServiceSnapshot) {
            self.snapshot = snapshot
        }

        func configure(settings: LinkSettings, isForeground: Bool) {}

        func requestWhenInUseAuthorization() {
            snapshot.permission = .whenInUse
            onChange?()
        }

        func requestAlwaysAuthorization() {
            snapshot.permission = .always
            onChange?()
        }

        func startUpdating() {
            snapshot.isUpdating = true
        }

        func stopUpdating() {
            snapshot.isUpdating = false
        }
    }

    @MainActor
    private final class UITestHealthNotificationService: HealthNotificationServicing {
        private(set) var authorizationStatus: HealthNotificationAuthorization
        var onAuthorizationChange: ((HealthNotificationAuthorization) -> Void)?
        var onError: ((HealthNotificationRequest?, String) -> Void)?

        init(authorizationStatus: HealthNotificationAuthorization) {
            self.authorizationStatus = authorizationStatus
        }

        func refreshAuthorization() {}

        func requestAuthorization() {
            guard authorizationStatus == .notDetermined else { return }
            authorizationStatus = .allowed
            onAuthorizationChange?(.allowed)
        }

        func schedule(_ request: HealthNotificationRequest) {}
        func remove(_ kinds: Set<HealthNotificationKind>) {}
        func removeLegacyRecoveryNotification() {}
        func removeAllHealthNotifications() {}
    }

    private final class UITestSettingsStore: LinkSettingsStoring {
        private var settings: LinkSettings
        private let shouldFail: Bool

        init(settings: LinkSettings, shouldFail: Bool) {
            self.settings = settings
            self.shouldFail = shouldFail
        }

        func load() throws -> LinkSettings { settings }

        func save(_ settings: LinkSettings) throws {
            if shouldFail {
                throw UITestSettingsError.expected
            }
            self.settings = settings
        }
    }

    private enum UITestSettingsError: Error {
        case expected
    }

    extension CameraServiceSnapshot {
        fileprivate static let fixture = CameraServiceSnapshot(
            state: .idle,
            discoveredCameraName: nil,
            targetName: "ILCE-7CM2",
            packetsSent: 0,
            lastSentAt: nil,
            includeTimezone: true,
            dd21ConfigHex: "06 10 00 9c 02 00 00",
            firmware: "2.01",
            protocolVersion: 101,
            profile: .modern,
            confidence: .verified,
            packetSize: 95,
            experimentalApprovalPending: false,
            pairingConfirmationPending: false,
            pairingStatus: "Not requested",
            cleanupDiagnostic: nil,
            operationOrder: [],
            lastError: nil,
            pendingReconnectArmed: false,
            activeLinkIntent: false,
            updateInterval: 120,
            diagnosticIdentity: SonyCameraIdentity(model: "ILCE-7CM2", firmware: "2.01", protocolVersion: 101)
        )
    }
#endif
