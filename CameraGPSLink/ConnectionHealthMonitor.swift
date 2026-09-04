import Foundation

struct ConnectionHealthMonitorContext {
    let cameraState: CameraConnectionState
    let packetsSent: Int
    let lastSentAt: Date?
    let activeLinkIntent: Bool
    let isForeground: Bool
    let backgroundLinkEnabled: Bool
    let alertsEnabled: Bool
    let authorization: HealthNotificationAuthorization
    let health: ConnectionHealth
    let now: Date
}

struct ConnectionHealthMonitorSnapshot: Equatable {
    var healthClassification = "Camera: No confirmed update; iPhone: No fix"
    var managedRequests: [HealthNotificationKind: Date] = [:]

    var pendingKindLabel: String {
        guard !managedRequests.isEmpty else { return "None" }
        return managedRequests.keys
            .sorted { $0.rawValue < $1.rawValue }
            .map(\.rawValue)
            .joined(separator: ", ")
    }

    var pendingDeadlineLabel: String {
        guard let deadline = managedRequests.values.min() else { return "—" }
        return deadline.formatted(date: .abbreviated, time: .standard)
    }
}

@MainActor
final class ConnectionHealthMonitor {
    private let notifications: HealthNotificationServicing
    private let diagnostics: DiagnosticsLogStore

    private(set) var snapshot = ConnectionHealthMonitorSnapshot()
    private(set) var hasReadySession = false

    private var previousCameraState: CameraConnectionState?
    private var managedRequests: [HealthNotificationKind: HealthNotificationRequest] = [:]
    private var scheduledStaleFor: Date?
    private var outageDueAt: Date?
    private var preservesForegroundSuspension = false
    private var didInitialReconcile = false
    private var didReconcileRestoredRequests = false
    private var didRemoveLegacyRecovery = false

    init(notifications: HealthNotificationServicing, diagnostics: DiagnosticsLogStore) {
        self.notifications = notifications
        self.diagnostics = diagnostics
    }

    func beginSession() {
        if hasReadySession, outageDueAt != nil {
            return
        }
        resetEpisode()
        removeAll(reason: "new session")
    }

    func endSession() {
        resetEpisode()
        removeAll(reason: "session ended")
    }

    func notificationRequestFailed(_ request: HealthNotificationRequest) {
        guard managedRequests[request.kind]?.generation == request.generation else { return }
        managedRequests.removeValue(forKey: request.kind)
        snapshot.managedRequests.removeValue(forKey: request.kind)
        if request.kind == .staleCameraUpdate {
            scheduledStaleFor = nil
        }
    }

    func appBecameActive() {
        guard preservesForegroundSuspension else { return }
        preservesForegroundSuspension = false
        remove([.foregroundSuspension])
    }

    func suspendForegroundOnly(using context: ConnectionHealthMonitorContext) {
        snapshot.healthClassification = context.health.diagnosticLabel
        guard hasReadySession || context.health.cameraUpdate.isFresh else {
            resetEpisode()
            removeAll(reason: "foreground-only session suspended before ready")
            return
        }

        resetEpisode()
        guard context.alertsEnabled, context.authorization.canDeliver else {
            removeAll(reason: "foreground-only session suspended without deliverable alerts")
            return
        }

        removeAll(reason: "foreground-only suspension")
        preservesForegroundSuspension = true
        schedule(.foregroundSuspension(deliveryDate: context.now))
        diagnostics.append("Health alert scheduled: foreground suspension")
    }

    func update(_ context: ConnectionHealthMonitorContext) {
        snapshot.healthClassification = context.health.diagnosticLabel

        if !context.alertsEnabled {
            resetEpisode()
            reconcileDisabled(reason: "alerts disabled")
            previousCameraState = context.cameraState
            return
        }
        if context.authorization == .denied {
            reconcileDisabled(reason: "notification permission blocked")
            previousCameraState = context.cameraState
            return
        }
        guard context.authorization.canDeliver else {
            previousCameraState = context.cameraState
            return
        }
        removeLegacyRecoveryIfNeeded()
        if preservesForegroundSuspension, !context.isForeground {
            previousCameraState = context.cameraState
            return
        }
        if !context.activeLinkIntent, !hasReadySession {
            reconcileDisabled(reason: "no active link intent")
            previousCameraState = context.cameraState
            return
        }

        let hasConfirmedUpdate = context.packetsSent > 0 && context.lastSentAt != nil
        let recoveredWithNewUpdate = hasConfirmedUpdate && context.cameraState == .linked && outageDueAt != nil

        if hasConfirmedUpdate, context.cameraState == .linked, !didReconcileRestoredRequests {
            remove([.linkLoss, .foregroundSuspension])
            didReconcileRestoredRequests = true
        }
        if recoveredWithNewUpdate {
            recover()
        }

        if hasConfirmedUpdate, context.cameraState == .linked, let lastSentAt = context.lastSentAt {
            hasReadySession = true
            scheduleStaleUpdateIfNeeded(lastSentAt: lastSentAt, now: context.now)
        }

        let lostCoverage = context.cameraState != .linked && context.cameraState != .pairing
        if hasReadySession, lostCoverage, outageDueAt == nil {
            scheduleOutage(now: context.now)
        } else {
            retryLinkLossIfNeeded(using: context)
        }

        didInitialReconcile = true
        previousCameraState = context.cameraState
    }

    private func scheduleStaleUpdateIfNeeded(lastSentAt: Date, now: Date) {
        guard scheduledStaleFor != lastSentAt else { return }
        remove([.staleCameraUpdate])
        scheduledStaleFor = lastSentAt
        let deadline = lastSentAt.addingTimeInterval(ConnectionHealthPolicy.cameraUpdateMaximumAge)
        schedule(.staleCameraUpdate(deliveryDate: deadline))
        diagnostics.append("Health alert scheduled: stale camera update")
    }

    private func scheduleOutage(now: Date) {
        remove([.staleCameraUpdate])
        scheduledStaleFor = nil
        let deadline = now.addingTimeInterval(ConnectionHealthPolicy.disconnectDebounce)
        outageDueAt = deadline
        schedule(.linkLoss(deliveryDate: deadline))
        diagnostics.append("Health alert scheduled: delayed link loss")
    }

    private func retryLinkLossIfNeeded(using context: ConnectionHealthMonitorContext) {
        guard hasReadySession,
            let outageDueAt,
            context.cameraState != .linked,
            managedRequests[.linkLoss] == nil
        else { return }
        schedule(.linkLoss(deliveryDate: outageDueAt))
        diagnostics.append("Health alert rescheduled: delayed link loss")
    }

    private func recover() {
        remove([.linkLoss])
        outageDueAt = nil
    }

    private func removeLegacyRecoveryIfNeeded() {
        guard !didRemoveLegacyRecovery else { return }
        notifications.removeLegacyRecoveryNotification()
        didRemoveLegacyRecovery = true
    }

    private func reconcileDisabled(reason: String) {
        guard !didInitialReconcile || !snapshot.managedRequests.isEmpty || !didReconcileRestoredRequests else {
            return
        }
        didInitialReconcile = true
        scheduledStaleFor = nil
        outageDueAt = nil
        removeAll(reason: reason)
    }

    private func schedule(_ request: HealthNotificationRequest) {
        notifications.schedule(request)
        managedRequests[request.kind] = request
        snapshot.managedRequests[request.kind] = request.deliveryDate
    }

    private func remove(_ kinds: Set<HealthNotificationKind>) {
        guard !kinds.isEmpty else { return }
        notifications.remove(kinds)
        for kind in kinds {
            managedRequests.removeValue(forKey: kind)
            snapshot.managedRequests.removeValue(forKey: kind)
        }
    }

    private func removeAll(reason: String) {
        let hadRequests = !snapshot.managedRequests.isEmpty
        notifications.removeAllHealthNotifications()
        didReconcileRestoredRequests = true
        didRemoveLegacyRecovery = true
        managedRequests.removeAll()
        snapshot.managedRequests.removeAll()
        if hadRequests {
            diagnostics.append("Health alerts cleared: \(reason)")
        }
    }

    private func resetEpisode() {
        hasReadySession = false
        previousCameraState = nil
        scheduledStaleFor = nil
        outageDueAt = nil
        preservesForegroundSuspension = false
    }
}
