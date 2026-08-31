#if DEBUG
    import CoreLocation
    import Foundation

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

            switch scenario {
            case "not-connected", "empty-diagnostics":
                break
            case "first-run":
                permission = .notDetermined
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
            return CameraGPSLinkAppModel(
                cameraService: cameraService,
                locationService: locationService,
                settingsStore: store,
                diagnosticsStore: diagnostics,
                now: { now },
                openSettings: {},
                releasePolicy: releasePolicy
            )
        }

        private static func fixtureLocation(now: Date) -> CLLocation {
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 35.681236, longitude: 139.767125),
                altitude: 10,
                horizontalAccuracy: 8,
                verticalAccuracy: 10,
                timestamp: now
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
            snapshot.pairingConfirmationPending = true
            snapshot.pairingStatus = "Confirmation required"
            onChange?()
        }

        func confirmPairingInitialization() {
            snapshot.pairingConfirmationPending = false
            snapshot.pairingStatus = "Pairing initialization sent"
            onChange?()
        }

        func cancelPairingInitialization() {
            snapshot.pairingConfirmationPending = false
            snapshot.pairingStatus = "Cancelled without a GATT write"
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
            updateInterval: 120
        )
    }
#endif
