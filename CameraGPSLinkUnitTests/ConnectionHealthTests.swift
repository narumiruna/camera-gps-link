import CoreLocation
import UserNotifications
import XCTest

@testable import CameraGPSLink

final class ConnectionHealthPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    func testLocationFreshnessAndAccuracyBoundariesAreInclusive() {
        XCTAssertEqual(fix(age: 120, accuracy: 100), .healthy(meters: 100, age: 120))
        XCTAssertEqual(fix(age: -10, accuracy: 100), .healthy(meters: 100, age: -10))
        XCTAssertEqual(fix(age: 121, accuracy: 5), .stale(age: 121))
        XCTAssertEqual(fix(age: -11, accuracy: 5), .future(skew: 11))
        XCTAssertEqual(fix(age: 0, accuracy: 101), .lowAccuracy(meters: 101, age: 0))
        XCTAssertEqual(fix(age: 0, accuracy: -1), .invalid)
        XCTAssertEqual(fix(age: 0, accuracy: .infinity), .invalid)
        XCTAssertEqual(
            ConnectionHealthEvaluator.locationFix(timestamp: nil, horizontalAccuracy: nil, now: now),
            .missing
        )
    }

    func testCameraAndPhoneFreshnessRemainIndependent() {
        let boundary = ConnectionHealthEvaluator.evaluate(
            packetsSent: 1,
            lastSentAt: now.addingTimeInterval(-300),
            locationTimestamp: now.addingTimeInterval(-121),
            horizontalAccuracy: 8,
            now: now
        )
        XCTAssertTrue(boundary.cameraUpdate.isFresh)
        XCTAssertEqual(boundary.locationFix, .stale(age: 121))

        let stale = ConnectionHealthEvaluator.evaluate(
            packetsSent: 1,
            lastSentAt: now.addingTimeInterval(-301),
            locationTimestamp: now,
            horizontalAccuracy: 8,
            now: now
        )
        XCTAssertFalse(stale.cameraUpdate.isFresh)
        XCTAssertTrue(stale.locationFix.isReady)
    }

    private func fix(age: TimeInterval, accuracy: Double) -> LocationFixHealth {
        ConnectionHealthEvaluator.locationFix(
            timestamp: now.addingTimeInterval(-age),
            horizontalAccuracy: accuracy,
            now: now
        )
    }
}

final class GeotaggingHealthViewStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    func testStaleFixWarnsWithoutDiscardingFreshCameraCache() {
        let state = makeState(locationAge: 121, accuracy: 8)

        XCTAssertEqual(state.phase, .ready)
        XCTAssertEqual(locationDetail(in: state), "Stale · 2 minutes ago")
        XCTAssertEqual(state.notices.first?.id, "location-stale")
        XCTAssertNil(state.secondaryAction)
    }

    func testLowAccuracyIsWritableButNotLocationReady() {
        let state = makeState(locationAge: 0, accuracy: 101)

        XCTAssertEqual(state.phase, .ready)
        XCTAssertEqual(locationDetail(in: state), "Low accuracy · ±101 m")
        XCTAssertFalse(locationItem(in: state).isReady)
        XCTAssertEqual(state.notices.first?.id, "location-low-accuracy")
        XCTAssertEqual(state.secondaryAction, .sendNow)
    }

    func testInvalidFutureMissingAndHealthyFixesHaveDistinctCopy() {
        XCTAssertEqual(locationDetail(in: makeState(locationAge: -11, accuracy: 8)), "Fix time invalid")
        XCTAssertEqual(locationDetail(in: makeState(locationAge: 0, accuracy: -1)), "Invalid fix")
        XCTAssertEqual(locationDetail(in: makeState(locationAge: nil, accuracy: nil)), "No fix yet")
        XCTAssertEqual(locationDetail(in: makeState(locationAge: 0, accuracy: 8)), "Ready · ±8 m")
    }

    func testStaleCameraUpdateIsNotReadyAndSafetyNoticePrecedesPermission() {
        var snapshot = makeSnapshot(locationAge: 121, accuracy: 8, sentAge: 301)
        snapshot.backgroundEnabled = true
        snapshot.locationPermission = .whenInUse
        let state = GeotaggingViewState.make(from: snapshot, now: now)

        XCTAssertEqual(state.phase, .needsAttention)
        XCTAssertEqual(state.primaryAction, .stop)
        XCTAssertEqual(state.notices.map(\.id), ["location-stale", "background-permission"])
        XCTAssertFalse(state.readiness.first(where: { $0.id == "update" })?.isReady ?? true)
    }

    private func makeState(locationAge: TimeInterval?, accuracy: Double?) -> GeotaggingViewState {
        GeotaggingViewState.make(
            from: makeSnapshot(locationAge: locationAge, accuracy: accuracy, sentAge: 12),
            now: now
        )
    }

    private func makeSnapshot(
        locationAge: TimeInterval?,
        accuracy: Double?,
        sentAge: TimeInterval
    ) -> GeotaggingSnapshot {
        let timestamp = locationAge.map { now.addingTimeInterval(-$0) }
        let health = ConnectionHealthEvaluator.evaluate(
            packetsSent: 1,
            lastSentAt: now.addingTimeInterval(-sentAge),
            locationTimestamp: timestamp,
            horizontalAccuracy: accuracy,
            now: now
        )
        return GeotaggingSnapshot(
            cameraState: .linked,
            cameraName: "Camera",
            targetName: "Camera",
            packetsSent: 1,
            lastSentAt: now.addingTimeInterval(-sentAge),
            locationPermission: .whenInUse,
            hasLocation: health.locationFix.isWritable,
            horizontalAccuracy: accuracy,
            locationTimestamp: timestamp,
            health: health,
            backgroundEnabled: false,
            isForeground: true,
            pendingReconnectArmed: false,
            transientError: nil
        )
    }

    private func locationItem(in state: GeotaggingViewState) -> ReadinessItem {
        state.readiness.first(where: { $0.id == "location" })!
    }

    private func locationDetail(in state: GeotaggingViewState) -> String {
        locationItem(in: state).detail
    }
}

final class HealthNotificationRequestTests: XCTestCase {
    func testRequestsUseStableGenericPayloadsAndForegroundRouting() {
        let now = Date(timeIntervalSince1970: 10_000)
        let requests = [
            HealthNotificationRequest.linkLoss(deliveryDate: now),
            .staleCameraUpdate(deliveryDate: now),
            .foregroundSuspension(deliveryDate: now),
        ]

        XCTAssertEqual(Set(requests.map(\.kind)), Set(HealthNotificationKind.allCases))
        XCTAssertEqual(Set(requests.map(\.generation)).count, requests.count)
        XCTAssertEqual(Set(HealthNotificationKind.identifiers).count, HealthNotificationKind.allCases.count + 1)
        XCTAssertTrue(HealthNotificationKind.identifiers.contains(HealthNotificationKind.legacyRecoveryIdentifier))
        XCTAssertEqual(
            Set(HealthNotificationKind.allCases.map(\.rawValue)),
            Set(["link-loss", "stale-camera-update", "foreground-suspension"])
        )
        for request in requests {
            let payload = "\(request.title) \(request.body) \(request.kind.identifier)"
            XCTAssertFalse(payload.contains("ILCE"))
            XCTAssertFalse(payload.contains("2.01"))
            XCTAssertFalse(payload.contains("35."))
            XCTAssertFalse(payload.contains("139."))
            XCTAssertTrue(request.kind.identifier.hasPrefix("dev.narumi.cameragpslink.health."))
        }
        XCTAssertEqual(
            LocalHealthNotificationService.foregroundOptions(for: HealthNotificationKind.linkLoss.identifier),
            [.banner, .list, .sound]
        )
        XCTAssertTrue(
            requests.first(where: { $0.kind == .foregroundSuspension })?.body.contains(
                "tap Start Geotagging"
            ) == true
        )
        XCTAssertEqual(LocalHealthNotificationService.foregroundOptions(for: "unrelated"), [])
        XCTAssertEqual(LocalHealthNotificationService.map(.notDetermined), .notDetermined)
        XCTAssertEqual(LocalHealthNotificationService.map(.denied), .denied)
        XCTAssertEqual(LocalHealthNotificationService.map(.authorized), .allowed)
        XCTAssertEqual(LocalHealthNotificationService.map(.provisional), .allowed)
        XCTAssertEqual(LocalHealthNotificationService.map(.ephemeral), .allowed)
    }
}

@MainActor
final class ConnectionHealthMonitorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    func testSuccessfulSendSchedulesOneStaleRequestAndDeduplicatesCallbacks() {
        let (monitor, notifications) = makeMonitor()
        let context = readyContext(at: now)

        monitor.update(context)
        monitor.update(context)

        XCTAssertEqual(notifications.scheduled.count, 1)
        XCTAssertEqual(notifications.scheduled.first?.kind, .staleCameraUpdate)
        XCTAssertEqual(notifications.scheduled.first?.deliveryDate, now.addingTimeInterval(300))
        XCTAssertEqual(monitor.snapshot.managedRequests[.staleCameraUpdate], now.addingTimeInterval(300))
    }

    func testFastDisconnectCancelsLossWithoutStandaloneRecoveryAlert() {
        let (monitor, notifications) = makeMonitor()
        monitor.update(readyContext(at: now))
        monitor.update(disconnectedContext(at: now))

        XCTAssertEqual(notifications.scheduled.last?.kind, .linkLoss)
        XCTAssertEqual(notifications.scheduled.last?.deliveryDate, now.addingTimeInterval(10))

        monitor.update(readyContext(at: now.addingTimeInterval(5), sentAt: now.addingTimeInterval(5)))

        XCTAssertTrue(notifications.removed.contains(Set([.linkLoss])))
        XCTAssertEqual(notifications.scheduled.map(\.kind), [.staleCameraUpdate, .linkLoss, .staleCameraUpdate])
    }

    func testProlongedOutageCancelsLossWithoutStandaloneRecoveryAlert() {
        let (monitor, notifications) = makeMonitor()
        monitor.update(readyContext(at: now))
        monitor.update(disconnectedContext(at: now))
        let recovered = readyContext(at: now.addingTimeInterval(11), sentAt: now.addingTimeInterval(11))

        monitor.update(recovered)
        monitor.update(recovered)

        XCTAssertTrue(notifications.removed.contains(Set([.linkLoss])))
        XCTAssertEqual(notifications.scheduled.map(\.kind), [.staleCameraUpdate, .linkLoss, .staleCameraUpdate])
    }

    func testRestoredIntentKeepsThenFreshSendClearsUnknownOutageRequests() {
        let (monitor, notifications) = makeMonitor()
        monitor.update(context(state: .connecting, activeIntent: true, isForeground: false, at: now))

        XCTAssertEqual(notifications.removeAllCount, 0)
        XCTAssertTrue(notifications.scheduled.isEmpty)
        XCTAssertEqual(notifications.legacyRecoveryRemovalCount, 1)
        monitor.update(context(state: .connecting, activeIntent: true, isForeground: false, at: now))
        XCTAssertEqual(notifications.legacyRecoveryRemovalCount, 1)

        let sentAt = now.addingTimeInterval(1)
        monitor.update(readyContext(at: sentAt, sentAt: sentAt))

        let restoredKinds = Set([HealthNotificationKind.linkLoss, .foregroundSuspension])
        XCTAssertTrue(notifications.removed.contains(restoredKinds))
        XCTAssertEqual(notifications.scheduled.last?.kind, .staleCameraUpdate)
        let reconciliationCount = notifications.removed.filter { $0 == restoredKinds }.count

        monitor.update(readyContext(at: sentAt, sentAt: sentAt))

        XCTAssertEqual(notifications.removed.filter { $0 == restoredKinds }.count, reconciliationCount)
    }

    func testRestoredIntentTerminalClearRemovesUnknownRequests() {
        let (monitor, notifications) = makeMonitor()
        monitor.update(context(state: .connecting, activeIntent: true, isForeground: false, at: now))
        XCTAssertEqual(notifications.removeAllCount, 0)

        monitor.update(context(state: .unsupported, activeIntent: false, isForeground: false, at: now))

        XCTAssertEqual(notifications.removeAllCount, 1)
    }

    func testDisconnectedRefreshDoesNotRecreateStaleAlertFromCachedSend() {
        let (monitor, notifications) = makeMonitor()
        monitor.update(readyContext(at: now))
        let disconnected = context(
            state: .connecting,
            packets: 1,
            sentAt: now,
            activeIntent: true,
            isForeground: false,
            backgroundEnabled: true,
            at: now
        )

        monitor.update(disconnected)
        monitor.update(disconnected)

        XCTAssertEqual(notifications.scheduled.filter { $0.kind == .staleCameraUpdate }.count, 1)
        XCTAssertNil(monitor.snapshot.managedRequests[.staleCameraUpdate])
        XCTAssertNotNil(monitor.snapshot.managedRequests[.linkLoss])
    }

    func testPermissionRestoreRearmsPreviouslyReadyDisconnectedEpisode() {
        let (monitor, notifications) = makeMonitor()
        monitor.update(readyContext(at: now))
        monitor.update(
            context(
                state: .connecting,
                activeIntent: true,
                isForeground: false,
                backgroundEnabled: true,
                authorization: .denied,
                at: now
            )
        )
        let linkLossCount = notifications.scheduled.filter { $0.kind == .linkLoss }.count

        monitor.update(disconnectedContext(at: now.addingTimeInterval(30)))

        XCTAssertEqual(notifications.scheduled.filter { $0.kind == .linkLoss }.count, linkLossCount + 1)
    }

    func testFailureCleanupStoppingStateSchedulesLossAfterReady() {
        let (monitor, notifications) = makeMonitor()
        monitor.update(readyContext(at: now))

        monitor.update(context(state: .stopping, activeIntent: false, at: now))

        XCTAssertEqual(notifications.scheduled.last?.kind, .linkLoss)
    }

    func testInitialFailureAndIntentionalEndNeverScheduleLoss() {
        let (monitor, notifications) = makeMonitor()
        monitor.beginSession()
        monitor.update(context(state: .connecting, activeIntent: true, at: now))
        monitor.update(context(state: .failed, activeIntent: false, at: now))
        monitor.endSession()

        XCTAssertFalse(notifications.scheduled.contains(where: { $0.kind == .linkLoss }))
    }

    func testIntentionalEndAndPairingSuppressLossAndClearOwnedRequests() {
        let (monitor, notifications) = makeMonitor()
        monitor.update(readyContext(at: now))
        monitor.update(context(state: .pairing, activeIntent: true, at: now))
        XCTAssertFalse(notifications.scheduled.contains(where: { $0.kind == .linkLoss }))

        monitor.endSession()
        let linkLossCount = notifications.scheduled.filter { $0.kind == .linkLoss }.count
        monitor.update(context(state: .stopping, activeIntent: false, at: now))

        XCTAssertGreaterThanOrEqual(notifications.removeAllCount, 1)
        XCTAssertTrue(monitor.snapshot.managedRequests.isEmpty)
        XCTAssertEqual(notifications.scheduled.filter { $0.kind == .linkLoss }.count, linkLossCount)
    }

    func testForegroundOnlySuspensionReplacesCompetingRequests() {
        let (monitor, notifications) = makeMonitor()
        let ready = readyContext(at: now)
        monitor.update(ready)

        monitor.suspendForegroundOnly(
            using: context(
                state: .linked,
                packets: 1,
                sentAt: now,
                activeIntent: true,
                isForeground: false,
                at: now
            )
        )

        XCTAssertEqual(notifications.scheduled.last?.kind, .foregroundSuspension)
        XCTAssertEqual(Set(monitor.snapshot.managedRequests.keys), [.foregroundSuspension])
        monitor.update(context(state: .stopped, activeIntent: false, isForeground: false, at: now))
        XCTAssertEqual(Set(monitor.snapshot.managedRequests.keys), [.foregroundSuspension])

        monitor.appBecameActive()
        XCTAssertTrue(notifications.removed.contains(Set([.foregroundSuspension])))
    }

    func testBackgroundEnabledSessionDoesNotUseForegroundSuspensionPath() {
        let (monitor, notifications) = makeMonitor()
        monitor.update(readyContext(at: now, backgroundEnabled: true))
        monitor.update(
            context(
                state: .connecting,
                activeIntent: true,
                isForeground: false,
                backgroundEnabled: true,
                at: now
            )
        )

        XCTAssertFalse(notifications.scheduled.contains(where: { $0.kind == .foregroundSuspension }))
        XCTAssertTrue(notifications.scheduled.contains(where: { $0.kind == .linkLoss }))
    }

    func testObsoleteStaleFailureCannotDeleteReplacementAndCurrentFailureRetries() {
        let (monitor, notifications) = makeMonitor()
        let firstContext = readyContext(at: now)
        monitor.update(firstContext)
        let obsoleteRequest = notifications.scheduled.last!
        let replacementTime = now.addingTimeInterval(1)
        let replacementContext = readyContext(at: replacementTime, sentAt: replacementTime)
        monitor.update(replacementContext)
        let replacementRequest = notifications.scheduled.last!

        monitor.notificationRequestFailed(obsoleteRequest)

        XCTAssertEqual(monitor.snapshot.managedRequests[.staleCameraUpdate], replacementTime.addingTimeInterval(300))
        XCTAssertNotEqual(obsoleteRequest.generation, replacementRequest.generation)
        let scheduleCount = notifications.scheduled.count

        monitor.notificationRequestFailed(replacementRequest)
        monitor.update(replacementContext)

        XCTAssertEqual(notifications.scheduled.count, scheduleCount + 1)
        XCTAssertEqual(monitor.snapshot.managedRequests[.staleCameraUpdate], replacementTime.addingTimeInterval(300))
    }

    func testLinkLossSchedulingFailurePreservesOutageAndRetriesOnLaterUpdate() {
        let (monitor, notifications) = makeMonitor()
        monitor.update(readyContext(at: now))
        let disconnected = disconnectedContext(at: now)
        monitor.update(disconnected)
        let failedRequest = notifications.scheduled.last!

        monitor.notificationRequestFailed(failedRequest)
        XCTAssertTrue(monitor.hasReadySession)
        XCTAssertNil(monitor.snapshot.managedRequests[.linkLoss])

        monitor.update(disconnectedContext(at: now.addingTimeInterval(30)))

        let linkLossRequests = notifications.scheduled.filter { $0.kind == .linkLoss }
        XCTAssertEqual(linkLossRequests.count, 2)
        XCTAssertNotEqual(linkLossRequests[0].generation, linkLossRequests[1].generation)
        XCTAssertEqual(linkLossRequests[1].deliveryDate, now.addingTimeInterval(10))
    }

    func testDisabledOrDeniedAlertsRemoveOnlyOwnedKindsAndCanReschedule() {
        let (monitor, notifications) = makeMonitor()
        monitor.update(readyContext(at: now))
        monitor.update(readyContext(at: now, alertsEnabled: false))
        XCTAssertGreaterThanOrEqual(notifications.removeAllCount, 1)

        monitor.update(readyContext(at: now, authorization: .denied))
        let countBeforeAuthorization = notifications.scheduled.count
        monitor.update(readyContext(at: now, authorization: .allowed))
        XCTAssertEqual(notifications.scheduled.count, countBeforeAuthorization + 1)
        XCTAssertEqual(Set(HealthNotificationKind.identifiers).intersection(["unrelated"]), [])
    }

    private func makeMonitor() -> (ConnectionHealthMonitor, RecordingHealthNotificationService) {
        let notifications = RecordingHealthNotificationService(authorizationStatus: .allowed)
        return (
            ConnectionHealthMonitor(notifications: notifications, diagnostics: DiagnosticsLogStore()),
            notifications
        )
    }

    private func readyContext(
        at currentTime: Date,
        sentAt: Date? = nil,
        backgroundEnabled: Bool = false,
        alertsEnabled: Bool = true,
        authorization: HealthNotificationAuthorization = .allowed
    ) -> ConnectionHealthMonitorContext {
        context(
            state: .linked,
            packets: 1,
            sentAt: sentAt ?? now,
            activeIntent: true,
            isForeground: true,
            backgroundEnabled: backgroundEnabled,
            alertsEnabled: alertsEnabled,
            authorization: authorization,
            at: currentTime
        )
    }

    private func disconnectedContext(at currentTime: Date) -> ConnectionHealthMonitorContext {
        context(state: .connecting, activeIntent: true, isForeground: false, backgroundEnabled: true, at: currentTime)
    }

    private func context(
        state: CameraConnectionState,
        packets: Int = 0,
        sentAt: Date? = nil,
        activeIntent: Bool,
        isForeground: Bool = true,
        backgroundEnabled: Bool = false,
        alertsEnabled: Bool = true,
        authorization: HealthNotificationAuthorization = .allowed,
        at currentTime: Date
    ) -> ConnectionHealthMonitorContext {
        let health = ConnectionHealthEvaluator.evaluate(
            packetsSent: packets,
            lastSentAt: sentAt,
            locationTimestamp: currentTime,
            horizontalAccuracy: 8,
            now: currentTime
        )
        return ConnectionHealthMonitorContext(
            cameraState: state,
            packetsSent: packets,
            lastSentAt: sentAt,
            activeLinkIntent: activeIntent,
            isForeground: isForeground,
            backgroundLinkEnabled: backgroundEnabled,
            alertsEnabled: alertsEnabled,
            authorization: authorization,
            health: health,
            now: currentTime
        )
    }
}
