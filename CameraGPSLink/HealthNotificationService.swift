import Foundation
import UserNotifications

enum HealthNotificationAuthorization: String, Equatable {
    case notDetermined
    case allowed
    case denied

    var label: String {
        switch self {
        case .notDetermined:
            "Not Requested"
        case .allowed:
            "Allowed"
        case .denied:
            "Blocked in iOS Settings"
        }
    }

    var canDeliver: Bool { self == .allowed }
}

enum HealthNotificationKind: String, CaseIterable, Hashable {
    case linkLoss = "link-loss"
    case staleCameraUpdate = "stale-camera-update"
    case foregroundSuspension = "foreground-suspension"

    var identifier: String {
        "dev.narumi.cameragpslink.health.\(rawValue)"
    }

    static let legacyRecoveryIdentifier = "dev.narumi.cameragpslink.health.recovery"

    static var identifiers: [String] {
        allCases.map(\.identifier) + [legacyRecoveryIdentifier]
    }
}

struct HealthNotificationRequest: Equatable {
    let generation: UUID
    let kind: HealthNotificationKind
    let title: String
    let body: String
    let deliveryDate: Date

    init(
        generation: UUID = UUID(),
        kind: HealthNotificationKind,
        title: String,
        body: String,
        deliveryDate: Date
    ) {
        self.generation = generation
        self.kind = kind
        self.title = title
        self.body = body
        self.deliveryDate = deliveryDate
    }

    static func linkLoss(deliveryDate: Date) -> HealthNotificationRequest {
        HealthNotificationRequest(
            kind: .linkLoss,
            title: "Camera Link Interrupted",
            body: "Location updates are not reaching the camera. Open Camera GPS Link to check the connection.",
            deliveryDate: deliveryDate
        )
    }

    static func staleCameraUpdate(deliveryDate: Date) -> HealthNotificationRequest {
        HealthNotificationRequest(
            kind: .staleCameraUpdate,
            title: "Camera Location Is Out of Date",
            body:
                "The camera has not received a location update for five minutes. Open Camera GPS Link before shooting.",
            deliveryDate: deliveryDate
        )
    }

    static func foregroundSuspension(deliveryDate: Date) -> HealthNotificationRequest {
        HealthNotificationRequest(
            kind: .foregroundSuspension,
            title: "Geotagging Stopped",
            body: "Camera GPS Link must stay open in While App Is Open mode. Reopen the app and tap Start Geotagging.",
            deliveryDate: deliveryDate
        )
    }

}

@MainActor
protocol HealthNotificationServicing: AnyObject {
    var authorizationStatus: HealthNotificationAuthorization { get }
    var onAuthorizationChange: ((HealthNotificationAuthorization) -> Void)? { get set }
    var onError: ((HealthNotificationRequest?, String) -> Void)? { get set }

    func refreshAuthorization()
    func requestAuthorization()
    func schedule(_ request: HealthNotificationRequest)
    func remove(_ kinds: Set<HealthNotificationKind>)
    func removeLegacyRecoveryNotification()
    func removeAllHealthNotifications()
}

@MainActor
final class LocalHealthNotificationService: NSObject, HealthNotificationServicing, UNUserNotificationCenterDelegate {
    private(set) var authorizationStatus: HealthNotificationAuthorization = .notDetermined
    var onAuthorizationChange: ((HealthNotificationAuthorization) -> Void)?
    var onError: ((HealthNotificationRequest?, String) -> Void)?

    private let center: UNUserNotificationCenter
    private let now: () -> Date

    init(center: UNUserNotificationCenter = .current(), now: @escaping () -> Date = Date.init) {
        self.center = center
        self.now = now
        super.init()
        center.delegate = self
    }

    func refreshAuthorization() {
        center.getNotificationSettings { [weak self] settings in
            Task { @MainActor in
                self?.publishAuthorization(Self.map(settings.authorizationStatus))
            }
        }
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, error in
            Task { @MainActor in
                if let error {
                    self?.onError?(nil, "Health alert authorization failed: \(error.localizedDescription)")
                }
                self?.refreshAuthorization()
            }
        }
    }

    func schedule(_ request: HealthNotificationRequest) {
        guard authorizationStatus.canDeliver else { return }
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        content.threadIdentifier = "dev.narumi.cameragpslink.health"

        let interval = max(1, request.deliveryDate.timeIntervalSince(now()))
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let notificationRequest = UNNotificationRequest(
            identifier: request.kind.identifier,
            content: content,
            trigger: trigger
        )
        center.add(notificationRequest) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                self?.onError?(request, "Health alert scheduling failed: \(error.localizedDescription)")
            }
        }
    }

    func remove(_ kinds: Set<HealthNotificationKind>) {
        let identifiers = kinds.map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func removeLegacyRecoveryNotification() {
        let identifiers = [HealthNotificationKind.legacyRecoveryIdentifier]
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func removeAllHealthNotifications() {
        let identifiers = HealthNotificationKind.identifiers
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(Self.foregroundOptions(for: notification.request.identifier))
    }

    nonisolated static func foregroundOptions(for identifier: String) -> UNNotificationPresentationOptions {
        guard identifier.hasPrefix("dev.narumi.cameragpslink.health.") else { return [] }
        return [.banner, .list, .sound]
    }

    private func publishAuthorization(_ status: HealthNotificationAuthorization) {
        guard status != authorizationStatus else { return }
        authorizationStatus = status
        onAuthorizationChange?(status)
    }

    nonisolated static func map(_ status: UNAuthorizationStatus) -> HealthNotificationAuthorization {
        switch status {
        case .notDetermined:
            .notDetermined
        case .denied:
            .denied
        case .authorized, .provisional, .ephemeral:
            .allowed
        @unknown default:
            .denied
        }
    }
}

@MainActor
final class NoopHealthNotificationService: HealthNotificationServicing {
    private(set) var authorizationStatus: HealthNotificationAuthorization
    var onAuthorizationChange: ((HealthNotificationAuthorization) -> Void)?
    var onError: ((HealthNotificationRequest?, String) -> Void)?

    init(authorizationStatus: HealthNotificationAuthorization = .denied) {
        self.authorizationStatus = authorizationStatus
    }

    func refreshAuthorization() {}
    func requestAuthorization() {}
    func schedule(_ request: HealthNotificationRequest) {}
    func remove(_ kinds: Set<HealthNotificationKind>) {}
    func removeLegacyRecoveryNotification() {}
    func removeAllHealthNotifications() {}
}
