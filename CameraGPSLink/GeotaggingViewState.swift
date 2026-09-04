import CoreLocation
import Foundation

enum LocationPermission: Equatable {
    case notDetermined
    case denied
    case restricted
    case whenInUse
    case always
    case unknown

    init(_ status: CLAuthorizationStatus) {
        switch status {
        case .notDetermined:
            self = .notDetermined
        case .denied:
            self = .denied
        case .restricted:
            self = .restricted
        case .authorizedAlways:
            self = .always
        #if os(iOS)
            case .authorizedWhenInUse:
                self = .whenInUse
        #endif
        @unknown default:
            self = .unknown
        }
    }

    var label: String {
        switch self {
        case .notDetermined:
            "Not requested"
        case .denied:
            "Denied"
        case .restricted:
            "Restricted"
        case .whenInUse:
            "While using app"
        case .always:
            "Always"
        case .unknown:
            "Unknown"
        }
    }

    var allowsForegroundLocation: Bool {
        self == .whenInUse || self == .always
    }
}

enum GeotaggingPhase: Equatable {
    case notConnected
    case requestingPermission
    case searching
    case connecting
    case preparing
    case approvalRequired
    case unsupported
    case waitingForLocation
    case sendingFirstLocation
    case ready
    case waitingInBackground
    case stopping
    case stopped
    case needsAttention
}

enum GeotaggingAction: Equatable {
    case start
    case cancel
    case approveExperimental
    case retry
    case stop
    case sendNow
    case openSettings
    case requestBackgroundPermission
}

struct ReadinessItem: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let symbolName: String
    let isReady: Bool
}

struct StatusNotice: Identifiable, Equatable {
    let id: String
    let title: String
    let message: String
    let action: GeotaggingAction?
    let actionLabel: String?
}

struct GeotaggingSnapshot: Equatable {
    var cameraState: CameraConnectionState
    var cameraName: String?
    var targetName: String
    var packetsSent: Int
    var lastSentAt: Date?
    var locationPermission: LocationPermission
    var hasLocation: Bool
    var horizontalAccuracy: CLLocationAccuracy?
    var locationTimestamp: Date?
    var health: ConnectionHealth?
    var backgroundEnabled: Bool
    var isForeground: Bool
    var pendingReconnectArmed: Bool
    var transientError: String?
    var isRequestingPermission = false
    var experimentalApprovalPending = false
    var profile: SonyLocationProfileKind?
    var confidence: SonySupportConfidence = .experimental
    var firmware: String?
    var protocolVersion: Int?
    var packetSize: Int?
    var cleanupDiagnostic: String?
    var allowsExperimentalApproval = true
}

struct GeotaggingViewState: Equatable {
    var phase: GeotaggingPhase
    var title: String
    var message: String
    var readiness: [ReadinessItem]
    var primaryAction: GeotaggingAction?
    var primaryActionLabel: String?
    var secondaryAction: GeotaggingAction?
    var secondaryActionLabel: String?
    var showsProgress: Bool
    var lastUpdateText: String
    var notices: [StatusNotice]

    var notice: String? {
        notices.first(where: { $0.id == "background-permission" })?.title
    }

    var noticeAction: GeotaggingAction? {
        notices.first(where: { $0.id == "background-permission" })?.action
    }

    static func make(from snapshot: GeotaggingSnapshot, now: Date = Date()) -> GeotaggingViewState {
        let health = resolvedHealth(for: snapshot, now: now)
        let phase = phase(for: snapshot, health: health)
        let content = content(for: phase, snapshot: snapshot, now: now)
        let primary = primaryAction(for: phase, snapshot: snapshot, health: health)
        let lastUpdate = relativeUpdate(snapshot.lastSentAt, now: now)

        return GeotaggingViewState(
            phase: phase,
            title: content.title,
            message: snapshot.transientError ?? content.message,
            readiness: readiness(for: snapshot, health: health, lastUpdate: lastUpdate, now: now),
            primaryAction: primary,
            primaryActionLabel: label(for: primary),
            secondaryAction: phase == .ready && health.locationFix.isWritable
                ? .sendNow : (phase == .approvalRequired ? .cancel : nil),
            secondaryActionLabel: phase == .ready && health.locationFix.isWritable
                ? "Send Current Location" : (phase == .approvalRequired ? "Cancel" : nil),
            showsProgress: [
                .requestingPermission, .searching, .connecting, .preparing, .sendingFirstLocation, .stopping,
            ].contains(phase),
            lastUpdateText: lastUpdate,
            notices: notices(for: snapshot, health: health)
        )
    }

    private static func phase(
        for snapshot: GeotaggingSnapshot,
        health: ConnectionHealth
    ) -> GeotaggingPhase {
        if snapshot.isRequestingPermission {
            return .requestingPermission
        }
        if snapshot.locationPermission == .denied || snapshot.locationPermission == .restricted {
            return .needsAttention
        }
        if snapshot.backgroundEnabled,
            snapshot.pendingReconnectArmed,
            snapshot.cameraState == .connecting || snapshot.cameraState == .scanning
        {
            return .waitingInBackground
        }
        switch snapshot.cameraState {
        case .idle:
            return snapshot.locationPermission == .notDetermined ? .notConnected : .notConnected
        case .bluetoothUnavailable, .failed:
            return .needsAttention
        case .awaitingApproval:
            return snapshot.allowsExperimentalApproval ? .approvalRequired : .unsupported
        case .unsupported:
            return .unsupported
        case .scanning:
            return .searching
        case .connecting:
            return .connecting
        case .discovering, .enablingLocation, .pairing:
            return .preparing
        case .linked:
            guard snapshot.packetsSent > 0, snapshot.lastSentAt != nil else {
                return health.locationFix.isWritable ? .sendingFirstLocation : .waitingForLocation
            }
            return health.cameraUpdate.isFresh ? .ready : .needsAttention
        case .stopping:
            return .stopping
        case .stopped:
            return .stopped
        }
    }

    private static func content(
        for phase: GeotaggingPhase,
        snapshot: GeotaggingSnapshot,
        now: Date
    ) -> (title: String, message: String) {
        switch phase {
        case .notConnected:
            return ("Not Connected", "Start when your camera is on and ready for its Bluetooth location link.")
        case .requestingPermission:
            return ("Location Permission", "Confirm location access to start geotagging.")
        case .searching:
            return ("Looking for Camera…", "Keep the camera nearby and ready for its Bluetooth location link.")
        case .connecting:
            return ("Connecting…", "Connecting securely to \(snapshot.cameraName ?? snapshot.targetName).")
        case .preparing:
            return ("Preparing Location…", "Setting up the camera to receive iPhone location updates.")
        case .approvalRequired:
            let identity = [snapshot.cameraName ?? snapshot.targetName, snapshot.firmware.map { "firmware \($0)" }]
                .compactMap { $0 }
                .joined(separator: ", ")
            let profile = snapshot.profile?.rawValue ?? "unknown"
            return (
                "Experimental Camera Profile",
                "Review \(identity), protocol \(snapshot.protocolVersion.map(String.init) ?? "unknown"), "
                    + "\(profile) profile before allowing camera writes."
            )
        case .unsupported:
            return (
                "Unsupported Camera Profile",
                snapshot.transientError ?? "This camera’s discovered location characteristics cannot be used safely."
            )
        case .waitingForLocation:
            return (
                "Waiting for iPhone Location",
                "The camera is connected. Move to an open area if a GPS fix takes too long."
            )
        case .sendingFirstLocation:
            return ("Sending First Location…", "Wait for confirmation before taking geotagged photos.")
        case .ready:
            return ("Ready to Geotag", "New photos can use the latest location sent from this iPhone.")
        case .waitingInBackground:
            return (
                "Waiting for Camera", "Camera GPS Link will reconnect when the remembered camera becomes available."
            )
        case .stopping:
            return ("Stopping…", "Closing the camera location link safely.")
        case .stopped:
            return ("Stopped", "Location updates are off. Start again whenever you are ready.")
        case .needsAttention:
            if snapshot.locationPermission == .denied || snapshot.locationPermission == .restricted {
                return (
                    "Location Access Needed", "Location access is off. Review permission in iOS Settings, then retry."
                )
            }
            if snapshot.cameraState == .bluetoothUnavailable {
                return ("Bluetooth Unavailable", "Turn on Bluetooth and keep Camera GPS Link open, then retry.")
            }
            if snapshot.cameraState == .linked, let lastSentAt = snapshot.lastSentAt,
                now.timeIntervalSince(lastSentAt) > ConnectionHealthPolicy.cameraUpdateMaximumAge
            {
                return (
                    "Location Update Delayed", "The camera’s last location is out of date. Send again or reconnect."
                )
            }
            return ("Connection Needs Attention", "Check the camera and try connecting again.")
        }
    }

    private static func primaryAction(
        for phase: GeotaggingPhase,
        snapshot: GeotaggingSnapshot,
        health: ConnectionHealth
    ) -> GeotaggingAction? {
        switch phase {
        case .notConnected, .stopped:
            return .start
        case .requestingPermission, .searching, .connecting, .preparing, .unsupported:
            return .cancel
        case .approvalRequired:
            return .approveExperimental
        case .waitingForLocation, .sendingFirstLocation, .ready:
            return .stop
        case .needsAttention:
            if snapshot.locationPermission == .denied || snapshot.locationPermission == .restricted {
                return .openSettings
            }
            if snapshot.cameraState == .linked {
                return health.locationFix.isWritable ? .sendNow : .stop
            }
            return .retry
        case .waitingInBackground, .stopping:
            return nil
        }
    }

    private static func label(for action: GeotaggingAction?) -> String? {
        switch action {
        case .start:
            "Start Geotagging"
        case .cancel:
            "Cancel"
        case .approveExperimental:
            "Continue with Experimental Profile"
        case .retry:
            "Retry"
        case .stop:
            "Stop Geotagging"
        case .sendNow:
            "Send Current Location"
        case .openSettings:
            "Review Location Permission"
        case .requestBackgroundPermission:
            "Allow Background Location"
        case nil:
            nil
        }
    }

    static func relativeUpdate(_ date: Date?, now: Date) -> String {
        guard let date else { return "Never" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 5 { return "Just now" }
        if seconds < 60 { return "\(seconds) seconds ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) minute\(minutes == 1 ? "" : "s") ago" }
        let hours = minutes / 60
        return "\(hours) hour\(hours == 1 ? "" : "s") ago"
    }
}
