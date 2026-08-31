import CoreLocation
import XCTest

@testable import CameraGPSLink

@MainActor
final class CameraBLEManagerPlanIntegrationTests: XCTestCase {
    func testForegroundAttemptOriginSurvivesLinkedTransitionWhenBackgroundIsConfigured() {
        let manager = CameraBLEManager(
            diagnosticsStore: DiagnosticsLogStore(),
            timeoutPolicy: ForegroundConnectionTimeoutPolicy(),
            timeoutScheduler: .live,
            identityStore: InMemoryIdentityStore()
        )
        manager.backgroundLinkEnabled = true
        manager.attemptOrigin = .foreground

        manager.startSendingLocations()

        XCTAssertEqual(manager.attemptOrigin, .foreground)
        manager.stopTimer()
    }

    func testLateCallbackDebtPreventsTimedOutSetupAckFromCompletingCompensation() {
        let manager = CameraBLEManager(
            diagnosticsStore: DiagnosticsLogStore(),
            timeoutPolicy: ForegroundConnectionTimeoutPolicy(),
            timeoutScheduler: .live,
            identityStore: InMemoryIdentityStore()
        )
        let timedOut = PendingBLEOperation.write(
            name: "DD31 enable",
            uuid: manager.normalized(SonyProtocol.locationEnableUUID),
            required: true
        )

        manager.recordTimedOutCallback(for: timedOut)

        XCTAssertTrue(manager.consumeTimedOutCallback(kind: "write", uuid: SonyProtocol.locationEnableUUID))
        XCTAssertFalse(manager.consumeTimedOutCallback(kind: "write", uuid: SonyProtocol.locationEnableUUID))
    }

    func testLocationFreshnessRejectsStaleAndFutureFixes() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(CameraBLEManager.isLocationFresh(now.addingTimeInterval(-120), relativeTo: now))
        XCTAssertTrue(CameraBLEManager.isLocationFresh(now.addingTimeInterval(10), relativeTo: now))
        XCTAssertFalse(CameraBLEManager.isLocationFresh(now.addingTimeInterval(-121), relativeTo: now))
        XCTAssertFalse(CameraBLEManager.isLocationFresh(now.addingTimeInterval(11), relativeTo: now))
    }

    func testAnyDisconnectWithPossiblyAppliedControlsRequiresManualRecovery() {
        XCTAssertFalse(CameraBLEManager.disconnectLeavesCleanupIncomplete(SonyLocationAcquisition()))

        var notification = SonyLocationAcquisition()
        notification.recordAttempt(actionName: "DD01 notify")
        XCTAssertTrue(CameraBLEManager.disconnectLeavesCleanupIncomplete(notification))

        var lock = SonyLocationAcquisition()
        lock.recordAttempt(actionName: "DD30 lock")
        XCTAssertTrue(CameraBLEManager.disconnectLeavesCleanupIncomplete(lock))

        var transfer = SonyLocationAcquisition()
        transfer.recordAttempt(actionName: "DD31 enable")
        XCTAssertTrue(CameraBLEManager.disconnectLeavesCleanupIncomplete(transfer))
    }

    func testResolverRejectsDuplicateLocationCharacteristicUUIDs() {
        let descriptors = [
            SonyGattDescriptor(
                serviceUUID: SonyProtocol.locationServiceUUID,
                characteristicUUID: SonyProtocol.locationDataWriteUUID,
                properties: [.write]
            ),
            SonyGattDescriptor(
                serviceUUID: SonyProtocol.locationServiceUUID,
                characteristicUUID: SonyProtocol.locationDataWriteUUID,
                properties: [.write]
            ),
            SonyGattDescriptor(
                serviceUUID: SonyProtocol.locationServiceUUID,
                characteristicUUID: SonyProtocol.locationConfigReadUUID,
                properties: [.read]
            ),
        ]

        let profile = SonyLocationCapabilityResolver.resolve(
            protocolVersion: 64,
            descriptors: descriptors,
            discoveryComplete: true
        )

        XCTAssertEqual(profile.kind, .unsupported)
        XCTAssertTrue(profile.reason.contains("Duplicate characteristic"))
    }

    func testCompatibilityRegistryDoesNotTreatMissingFieldsAsWildcards() {
        let profile = SonyLocationProfile(
            kind: .modern,
            reason: "fixture",
            protocolVersion: 101,
            experimental: false,
            hasStatusNotifications: false,
            hasTimeCorrection: false,
            hasAreaAdjustment: false
        )
        let overbroad = SonyCompatibilityEntry(
            model: "ILCE-7M4",
            firmware: nil,
            protocolVersion: nil,
            profile: .modern,
            confidence: .verified,
            evidence: "fixture"
        )

        XCTAssertEqual(
            SonyLocationCapabilityResolver.compatibility(
                identity: SonyCameraIdentity(model: "ILCE-7M4", firmware: "4.00", protocolVersion: 101),
                profile: profile,
                verifiedEntries: [overbroad]
            ).confidence,
            .experimental
        )
        XCTAssertEqual(
            SonyLocationCapabilityResolver.compatibility(
                identity: SonyCameraIdentity(model: "ILCE-7M4", firmware: nil, protocolVersion: nil),
                profile: profile,
                verifiedEntries: [overbroad]
            ).confidence,
            .experimental
        )
    }

    func testServiceOwnershipMappingRejectsUnknownCharacteristicFamilies() {
        let manager = CameraBLEManager(
            diagnosticsStore: DiagnosticsLogStore(),
            timeoutPolicy: ForegroundConnectionTimeoutPolicy(),
            timeoutScheduler: .live,
            identityStore: InMemoryIdentityStore()
        )

        XCTAssertEqual(
            manager.expectedServiceUUID(for: SonyProtocol.locationDataWriteUUID), SonyProtocol.locationServiceUUID)
        XCTAssertEqual(
            manager.expectedServiceUUID(for: SonyProtocol.cameraModelUUID), SonyProtocol.cameraControlServiceUUID)
        XCTAssertEqual(manager.expectedServiceUUID(for: SonyProtocol.pairingInitUUID), SonyProtocol.pairingServiceUUID)
        XCTAssertNil(manager.expectedServiceUUID(for: "ff01"))
    }

    func testTerminalIntentClearPreventsAppModelBackgroundResume() {
        XCTAssertTrue(
            CameraGPSLinkAppModel.shouldClearLinkRequest(cameraState: .failed, activeLinkIntent: false)
        )
        XCTAssertTrue(
            CameraGPSLinkAppModel.shouldClearLinkRequest(cameraState: .unsupported, activeLinkIntent: false)
        )
        XCTAssertFalse(
            CameraGPSLinkAppModel.shouldClearLinkRequest(cameraState: .failed, activeLinkIntent: true)
        )
        XCTAssertFalse(
            CameraGPSLinkAppModel.shouldClearLinkRequest(cameraState: .scanning, activeLinkIntent: false)
        )
    }

    func testIdentityDecoderAcceptsTrailingNullPadding() {
        let manager = CameraBLEManager(
            diagnosticsStore: DiagnosticsLogStore(),
            timeoutPolicy: ForegroundConnectionTimeoutPolicy(),
            timeoutScheduler: .live,
            identityStore: InMemoryIdentityStore()
        )

        XCTAssertEqual(manager.decodeIdentity(Data("ILCE-7CM2\0\0".utf8)), "ILCE-7CM2")
        XCTAssertEqual(manager.decodeIdentity(Data("2.01\0".utf8)), "2.01")
    }

    func testDisconnectedCompensationFailureClearsPersistentIntent() {
        let manager = CameraBLEManager(
            diagnosticsStore: DiagnosticsLogStore(),
            timeoutPolicy: ForegroundConnectionTimeoutPolicy(),
            timeoutScheduler: .live,
            identityStore: InMemoryIdentityStore()
        )
        manager.acquisition.recordAttempt(actionName: "DD30 lock")
        manager.activeSessionRequested = true
        manager.manualStopRequested = false
        manager.setUserLinkIntent(active: true)

        manager.beginCompensation(finalState: .stopped, disconnectAfter: true)

        XCTAssertEqual(manager.state, .failed)
        XCTAssertEqual(manager.cleanupDiagnostic, "Incomplete cleanup: camera is disconnected")
        XCTAssertFalse(manager.activeSessionRequested)
        XCTAssertTrue(manager.manualStopRequested)
        XCTAssertFalse(manager.userLinkIntentActive)
    }

    func testUnsupportedResolutionEndsIntentAndRemainsTerminal() {
        let manager = CameraBLEManager(
            diagnosticsStore: DiagnosticsLogStore(),
            timeoutPolicy: ForegroundConnectionTimeoutPolicy(),
            timeoutScheduler: .live,
            identityStore: InMemoryIdentityStore()
        )
        manager.activeSessionRequested = true
        manager.manualStopRequested = false
        manager.attemptOrigin = .foreground
        manager.setUserLinkIntent(active: true)

        manager.rejectUnsupportedProfile("fixture rejection")

        XCTAssertEqual(manager.state, .unsupported)
        XCTAssertEqual(manager.lastError, "fixture rejection")
        XCTAssertFalse(manager.activeSessionRequested)
        XCTAssertTrue(manager.manualStopRequested)
        XCTAssertFalse(manager.userLinkIntentActive)
        XCTAssertEqual(manager.attemptOrigin, .none)
    }

    func testDD21ValidationFailureHonorsPendingCancellation() {
        let manager = CameraBLEManager(
            diagnosticsStore: DiagnosticsLogStore(),
            timeoutPolicy: ForegroundConnectionTimeoutPolicy(),
            timeoutScheduler: .live,
            identityStore: InMemoryIdentityStore()
        )
        manager.pendingOperation = .read(
            name: "DD21 preflight",
            uuid: manager.normalized(SonyProtocol.locationConfigReadUUID),
            required: true,
            onValue: nil
        )
        manager.cancelAfterCurrentOperation = true
        manager.state = .discovering

        manager.handleDD21PreflightValidationFailure("malformed fixture")

        XCTAssertEqual(manager.state, .stopped)
        XCTAssertFalse(manager.cancelAfterCurrentOperation)
        XCTAssertNil(manager.lastError)
    }

    func testDirectReconnectRequiresMatchingStoredProtocolContext() {
        let store = InMemoryIdentityStore()
        let manager = CameraBLEManager(
            diagnosticsStore: DiagnosticsLogStore(),
            timeoutPolicy: ForegroundConnectionTimeoutPolicy(),
            timeoutScheduler: .live,
            identityStore: store
        )
        let peripheralID = UUID().uuidString
        let descriptors: [SonyGattDescriptor] = []

        XCTAssertFalse(manager.hasValidatedRememberedProtocolContext(peripheralID: peripheralID))

        store.record = SonyValidatedIdentityRecord(
            peripheralID: peripheralID,
            identity: SonyCameraIdentity(model: "ILCE-7CM2", firmware: "2.01", protocolVersion: nil),
            profile: .modern,
            descriptorFingerprint: SonyLocationCapabilityResolver.descriptorFingerprint(descriptors)
        )
        XCTAssertFalse(manager.hasValidatedRememberedProtocolContext(peripheralID: peripheralID))

        store.record = SonyValidatedIdentityRecord(
            peripheralID: peripheralID,
            identity: SonyCameraIdentity(model: "ILCE-7CM2", firmware: "2.01", protocolVersion: 101),
            profile: .modern,
            descriptorFingerprint: SonyLocationCapabilityResolver.descriptorFingerprint(descriptors)
        )
        XCTAssertTrue(manager.hasValidatedRememberedProtocolContext(peripheralID: peripheralID))
        XCTAssertFalse(manager.hasValidatedRememberedProtocolContext(peripheralID: UUID().uuidString))
    }

    func testForegroundOnlyManagerStopsAndBlocksDD11InBackground() {
        let manager = CameraBLEManager(
            diagnosticsStore: DiagnosticsLogStore(),
            timeoutPolicy: ForegroundConnectionTimeoutPolicy(),
            timeoutScheduler: .live,
            identityStore: InMemoryIdentityStore(),
            releasePolicy: SonyReleasePolicy(mode: .publicRelease)
        )
        manager.configure(backgroundLinkEnabled: true, lowPowerModeEnabled: true)
        manager.state = .linked
        manager.activeSessionRequested = true
        manager.setUserLinkIntent(active: true)

        manager.handleScenePhase(isForeground: false)

        XCTAssertEqual(manager.state, .stopped)
        XCTAssertFalse(manager.permitsLocationWrites)
        XCTAssertFalse(manager.userLinkIntentActive)
        XCTAssertNil(manager.sendTimer)

        manager.state = .linked
        manager.setLocationProvider {
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 25.03, longitude: 121.56),
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: 5,
                timestamp: Date()
            )
        }
        manager.sendLocationIfDue(force: true)
        XCTAssertTrue(manager.sanitizedOperationOrder.isEmpty)
    }

    func testNewSessionClearsVolatileIdentityAndApprovalContext() {
        let manager = CameraBLEManager(
            diagnosticsStore: DiagnosticsLogStore(),
            timeoutPolicy: ForegroundConnectionTimeoutPolicy(),
            timeoutScheduler: .live,
            identityStore: InMemoryIdentityStore()
        )
        manager.currentIdentity = SonyCameraIdentity(model: "ILCE-7M4", firmware: "4.00", protocolVersion: 101)
        manager.releaseAuthorization = SonyReleaseAuthorization(
            requiresExperimentalApproval: true,
            expectedPacketSize: nil,
            confidence: .experimental
        )
        manager.sessionApprovalKey = "stale"
        manager.detectedFirmware = "4.00"
        manager.packetSize = 95

        manager.prepareForNewSession(resetCounters: false)

        XCTAssertNil(manager.currentIdentity)
        XCTAssertNil(manager.releaseAuthorization)
        XCTAssertNil(manager.sessionApprovalKey)
        XCTAssertNil(manager.detectedFirmware)
        XCTAssertNil(manager.packetSize)
    }

    func testStaleApprovalKeyCannotExecuteNewResolvedProfile() {
        let executor = RecordingSessionExecutor()
        let manager = CameraBLEManager(
            diagnosticsStore: DiagnosticsLogStore(),
            timeoutPolicy: ForegroundConnectionTimeoutPolicy(),
            timeoutScheduler: .live,
            identityStore: InMemoryIdentityStore(),
            sessionExecutor: executor
        )
        manager.currentIdentity = SonyCameraIdentity(model: "ILCE-6700", firmware: "2.00", protocolVersion: 101)
        manager.resolvedProfile = SonyLocationProfile(
            kind: .modern,
            reason: "fixture",
            protocolVersion: 101,
            experimental: false,
            hasStatusNotifications: false,
            hasTimeCorrection: false,
            hasAreaAdjustment: false
        )
        manager.supportConfidence = .experimental
        manager.releaseAuthorization = SonyReleaseAuthorization(
            requiresExperimentalApproval: true,
            expectedPacketSize: nil,
            confidence: .experimental
        )
        manager.sessionApprovalKey = "approval-for-another-camera"

        manager.beginLocationSetup()

        XCTAssertTrue(executor.plans.isEmpty)
        XCTAssertEqual(manager.state, .awaitingApproval)
        XCTAssertTrue(manager.experimentalApprovalPending)
    }

    func testManagerResolvesPlannerThenDelegatesToInjectedExecutor() {
        let planner = RecordingSessionPlanner()
        let executor = RecordingSessionExecutor()
        let manager = CameraBLEManager(
            diagnosticsStore: DiagnosticsLogStore(),
            timeoutPolicy: ForegroundConnectionTimeoutPolicy(),
            timeoutScheduler: .live,
            identityStore: InMemoryIdentityStore(),
            sessionPlanner: planner,
            sessionExecutor: executor
        )
        let profile = SonyLocationProfile(
            kind: .legacy,
            reason: "fixture",
            protocolVersion: 64,
            experimental: false,
            hasStatusNotifications: false,
            hasTimeCorrection: false,
            hasAreaAdjustment: false
        )
        manager.currentIdentity = SonyCameraIdentity(model: "ILCE-7M3", firmware: "4.01", protocolVersion: 64)
        manager.resolvedProfile = profile
        manager.supportConfidence = .verified
        manager.releaseAuthorization = SonyReleaseAuthorization(
            requiresExperimentalApproval: false,
            expectedPacketSize: 91,
            confidence: .verified
        )
        manager.packetSize = 91
        manager.activeSessionRequested = true

        manager.beginLocationSetup()

        XCTAssertEqual(planner.profiles, [profile])
        XCTAssertEqual(executor.plans.map(\.profile), [.legacy])
    }
}

private final class RecordingSessionPlanner: SonyLocationSessionPlanning {
    var profiles: [SonyLocationProfile] = []

    func makePlan(profile: SonyLocationProfile) -> SonyLocationSessionPlan {
        profiles.append(profile)
        return SonyLocationSessionPlan.make(profile: profile)
    }
}

private final class RecordingSessionExecutor: SonyLocationSessionExecuting {
    var plans: [SonyLocationSessionPlan] = []

    func execute(plan: SonyLocationSessionPlan, enqueue: (SonyLocationAction) -> Void) {
        plans.append(plan)
    }
}

private final class InMemoryIdentityStore: SonyValidatedIdentityStoring {
    var record: SonyValidatedIdentityRecord?
    func load() -> SonyValidatedIdentityRecord? { record }
    func save(_ record: SonyValidatedIdentityRecord) { self.record = record }
    func clear() { record = nil }
}
