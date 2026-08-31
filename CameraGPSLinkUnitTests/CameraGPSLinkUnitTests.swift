import Combine
import CoreLocation
import XCTest

@testable import CameraGPSLink

final class ForegroundConnectionTimeoutPolicyTests: XCTestCase {
    func testForegroundStagesHaveFiniteTimeouts() {
        let policy = ForegroundConnectionTimeoutPolicy()

        XCTAssertEqual(policy.timeout(for: .scanning), 15)
        XCTAssertEqual(policy.timeout(for: .connecting), 15)
        XCTAssertEqual(policy.timeout(for: .discovering), 15)
        XCTAssertEqual(policy.timeout(for: .preparing), 45)
    }

    func testStageTransitionCancelsOldTimeoutAndIgnoresLateCallback() {
        let scheduler = ManualConnectionTimeoutScheduler()
        var timedOutStages: [ForegroundConnectionStage] = []
        let session = ForegroundConnectionTimeoutSession(
            policy: ForegroundConnectionTimeoutPolicy(),
            scheduler: scheduler.scheduler,
            onTimeout: { timedOutStages.append($0) }
        )

        session.begin()
        session.transition(to: .scanning)
        session.transition(to: .connecting)
        scheduler.tokens[0].fireIgnoringCancellation()
        XCTAssertTrue(timedOutStages.isEmpty)

        scheduler.tokens[1].fireIgnoringCancellation()
        XCTAssertEqual(timedOutStages, [.connecting])
        XCTAssertFalse(session.isActive)
    }

    func testCancelAndBackgroundWithoutBeginNeverTimeout() {
        let scheduler = ManualConnectionTimeoutScheduler()
        var timeoutCount = 0
        let session = ForegroundConnectionTimeoutSession(
            policy: ForegroundConnectionTimeoutPolicy(),
            scheduler: scheduler.scheduler,
            onTimeout: { _ in timeoutCount += 1 }
        )

        session.transition(to: .scanning)
        XCTAssertTrue(scheduler.tokens.isEmpty)

        session.begin()
        session.transition(to: .preparing)
        session.end()
        scheduler.tokens[0].fireIgnoringCancellation()

        XCTAssertEqual(timeoutCount, 0)
        XCTAssertFalse(session.isActive)
    }
}

private final class ManualConnectionTimeoutScheduler {
    final class Token: ConnectionTimeoutCancellable {
        private(set) var isCancelled = false
        let action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        func cancel() { isCancelled = true }
        func fireIgnoringCancellation() { action() }
    }

    var tokens: [Token] = []

    lazy var scheduler = ConnectionTimeoutScheduler { [weak self] _, action in
        let token = Token(action: action)
        self?.tokens.append(token)
        return token
    }
}

final class DiagnosticsLogStoreTests: XCTestCase {
    func testLogIsBoundedAndCopyTextPreservesOrder() {
        let store = DiagnosticsLogStore(capacity: 2)

        store.append("first")
        store.append("second")
        store.append("third")

        XCTAssertEqual(store.lines, ["second", "third"])
        XCTAssertEqual(store.copyText, "second\nthird")
    }

    func testExportRedactsPeripheralIdentifiersAddressesAndManufacturerTails() {
        let store = DiagnosticsLogStore()
        store.append("Remembered 00000000-1111-2222-3333-444444444444 at aa:bb:cc:dd:ee:ff")
        store.append("manufacturer_data=03 00 65 00 de ad be ef")
        store.append("DD11 location OK 35.6812360, 139.7671250")
        store.append("DD01 notify ba ad f0 0d")

        XCTAssertFalse(store.copyText.contains("00000000-1111"))
        XCTAssertFalse(store.copyText.contains("aa:bb:cc"))
        XCTAssertFalse(store.copyText.contains("de ad be ef"))
        XCTAssertFalse(store.copyText.contains("35.6812360"))
        XCTAssertFalse(store.copyText.contains("ba ad f0 0d"))
        XCTAssertTrue(store.copyText.contains("[REDACTED]"))
    }
}

final class SonyLocationProfileTests: XCTestCase {
    private func descriptor(
        _ uuid: String,
        _ properties: Set<SonyGattProperty>,
        service: String = SonyProtocol.locationServiceUUID
    ) -> SonyGattDescriptor {
        SonyGattDescriptor(serviceUUID: service, characteristicUUID: uuid, properties: properties)
    }

    private func legacyShape() -> [SonyGattDescriptor] {
        [
            descriptor(SonyProtocol.locationDataWriteUUID, [.write]),
            descriptor(SonyProtocol.locationConfigReadUUID, [.read]),
        ]
    }

    private func modernShape() -> [SonyGattDescriptor] {
        legacyShape() + [
            descriptor(SonyProtocol.locationLockUUID, [.write]),
            descriptor(SonyProtocol.locationEnableUUID, [.write]),
            descriptor(SonyProtocol.locationStatusNotifyUUID, [.notify]),
        ]
    }

    func testResolverCoversModernLegacyExperimentalAndIncompleteShapes() {
        XCTAssertEqual(
            SonyLocationCapabilityResolver.resolve(
                protocolVersion: 101,
                descriptors: modernShape(),
                discoveryComplete: true
            ).kind,
            .modern
        )
        XCTAssertEqual(
            SonyLocationCapabilityResolver.resolve(
                protocolVersion: 64,
                descriptors: legacyShape(),
                discoveryComplete: true
            ).kind,
            .legacy
        )
        let unknownModern = SonyLocationCapabilityResolver.resolve(
            protocolVersion: nil,
            descriptors: modernShape(),
            discoveryComplete: true
        )
        XCTAssertEqual(unknownModern.kind, .modern)
        XCTAssertTrue(unknownModern.experimental)
        XCTAssertEqual(
            SonyLocationCapabilityResolver.resolve(
                protocolVersion: 101,
                descriptors: modernShape(),
                discoveryComplete: false
            ).kind,
            .unsupported
        )
    }

    func testResolverRejectsWrongServicePropertiesAndVersionShapes() {
        let wrongService = [
            descriptor(
                SonyProtocol.locationDataWriteUUID,
                [.write],
                service: SonyProtocol.remoteControlServiceUUID
            ),
            descriptor(SonyProtocol.locationConfigReadUUID, [.read]),
        ]
        XCTAssertEqual(
            SonyLocationCapabilityResolver.resolve(
                protocolVersion: 101,
                descriptors: wrongService,
                discoveryComplete: true
            ).kind,
            .unsupported
        )
        var wrongWrite = modernShape()
        wrongWrite[0] = descriptor(SonyProtocol.locationDataWriteUUID, [.writeWithoutResponse])
        XCTAssertEqual(
            SonyLocationCapabilityResolver.resolve(
                protocolVersion: 101,
                descriptors: wrongWrite,
                discoveryComplete: true
            ).kind,
            .unsupported
        )
        XCTAssertEqual(
            SonyLocationCapabilityResolver.resolve(
                protocolVersion: 64,
                descriptors: modernShape(),
                discoveryComplete: true
            ).kind,
            .unsupported
        )
        XCTAssertEqual(
            SonyLocationCapabilityResolver.resolve(
                protocolVersion: nil,
                descriptors: legacyShape(),
                discoveryComplete: true
            ).kind,
            .unsupported
        )
    }

    func testDD21StrictFramingCoversBothSizesAndMalformedVariants() throws {
        XCTAssertEqual(
            try SonyLocationCapabilityResolver.parseDD21(Data([0x06, 0x10, 0x00, 0x9C, 0x02, 0x00])).packetSize,
            95
        )
        XCTAssertEqual(
            try SonyLocationCapabilityResolver.parseDD21(Data([0x06, 0x10, 0x00, 0x9C, 0x00, 0x00, 0x00])).packetSize,
            91
        )
        for malformed in [
            Data(),
            Data([0x06, 0x10, 0x00, 0x9C, 0x02]),
            Data([0x06, 0x10, 0x00, 0x9C, 0x02, 0x00, 0x00, 0x00]),
            Data([0x05, 0x10, 0x00, 0x9C, 0x02, 0x00]),
            Data([0x06, 0x10, 0x00, 0x9C, 0x04, 0x00]),
            Data([0x06, 0x10, 0x00, 0x9C, 0x02, 0x01]),
        ] {
            XCTAssertThrowsError(try SonyLocationCapabilityResolver.parseDD21(malformed))
        }
    }

    func testSessionExecutorAndCompensationPreserveSafeOrder() {
        let profile = SonyLocationCapabilityResolver.resolve(
            protocolVersion: 101,
            descriptors: modernShape(),
            discoveryComplete: true
        )
        let plan = SonyLocationSessionPlan.make(profile: profile)
        var executed: [String] = []
        DefaultSonyLocationSessionExecutor().execute(plan: plan) { executed.append($0.name) }
        XCTAssertEqual(executed, ["DD01 notify", "DD30 lock", "DD31 enable"])

        var acquisition = SonyLocationAcquisition()
        acquisition.recordAttempt(actionName: "DD30 lock")
        XCTAssertEqual(acquisition.compensation.map(\.name), ["DD30 unlock"])
        acquisition.recordAttempt(actionName: "DD31 enable")
        XCTAssertEqual(acquisition.compensation.map(\.name), ["DD31 disable", "DD30 unlock"])
        acquisition.recordAttempt(actionName: "DD01 notify")
        XCTAssertEqual(
            acquisition.compensation.map(\.name),
            ["DD31 disable", "DD30 unlock", "DD01 notify stop"]
        )

        let legacy = SonyLocationAcquisition()
        XCTAssertTrue(legacy.compensation.isEmpty)
    }

    func testValidatedRecordRequiresFreshIdentityProfileAndDescriptorMatch() {
        let descriptors = modernShape()
        let identity = SonyCameraIdentity(model: "ILCE-7CM2", firmware: "2.01", protocolVersion: 101)
        let profile = SonyLocationCapabilityResolver.resolve(
            protocolVersion: 101,
            descriptors: descriptors,
            discoveryComplete: true
        )
        let record = SonyValidatedIdentityRecord(
            peripheralID: "private-id",
            identity: identity,
            profile: .modern,
            descriptorFingerprint: SonyLocationCapabilityResolver.descriptorFingerprint(descriptors)
        )

        XCTAssertTrue(
            record.matches(
                peripheralID: "private-id",
                identity: identity,
                profile: profile,
                descriptors: descriptors
            )
        )
        XCTAssertFalse(
            record.matches(
                peripheralID: "other-id",
                identity: identity,
                profile: profile,
                descriptors: descriptors
            )
        )
        XCTAssertFalse(
            record.matches(
                peripheralID: "private-id",
                identity: SonyCameraIdentity(model: "ILCE-7CM2", firmware: nil, protocolVersion: 101),
                profile: profile,
                descriptors: descriptors
            )
        )
    }

    func testUnsupportedCompatibilityEntryBlocksAnExecutableShape() {
        let identity = SonyCameraIdentity(model: "ILCE-7M4", firmware: "4.00", protocolVersion: 101)
        let executable = SonyLocationCapabilityResolver.resolve(
            protocolVersion: 101,
            descriptors: modernShape(),
            discoveryComplete: true
        )
        let compatibility = SonyLocationCapabilityResolver.compatibility(
            identity: identity,
            profile: executable,
            unsupportedEntries: [
                SonyCompatibilityEntry(
                    model: "LE_ILCE-7M4",
                    firmware: "4.00",
                    protocolVersion: 101,
                    profile: .modern,
                    confidence: .unsupported,
                    evidence: "blocked-fixture"
                )
            ]
        )
        let blocked = SonyLocationCapabilityResolver.resolve(
            protocolVersion: 101,
            descriptors: modernShape(),
            discoveryComplete: true,
            registryConfidence: compatibility.confidence
        )

        XCTAssertEqual(compatibility.confidence, .unsupported)
        XCTAssertEqual(blocked.kind, .unsupported)
    }

    func testHistoricalA7C2IdentityRemainsExperimentalUntilRequalified() {
        let profile = SonyLocationCapabilityResolver.resolve(
            protocolVersion: 101,
            descriptors: modernShape(),
            discoveryComplete: true
        )
        XCTAssertEqual(
            SonyLocationCapabilityResolver.compatibility(
                identity: SonyCameraIdentity(model: "LE_ILCE-7CM2", firmware: "2.01", protocolVersion: 101),
                profile: profile
            ).confidence,
            .experimental
        )
        XCTAssertEqual(
            SonyLocationCapabilityResolver.compatibility(
                identity: SonyCameraIdentity(model: "ILCE-7CM2", firmware: nil, protocolVersion: 101),
                profile: profile
            ).confidence,
            .experimental
        )
    }
}

final class LinkSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "CameraGPSLinkUnitTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testMissingLegacyKeysUseCompatibleDefaults() throws {
        let store = UserDefaultsLinkSettingsStore(defaults: defaults)

        XCTAssertEqual(try store.load(), .default)
        XCTAssertEqual(LinkSettings.default.connectionAvailability, .whileAppIsOpen)
        XCTAssertEqual(LinkSettings.default.locationUpdates, .batterySaver)
    }

    func testLegacyBooleanCombinationsMapToTypedSettings() throws {
        let store = UserDefaultsLinkSettingsStore(defaults: defaults)
        defaults.set(true, forKey: LinkSettingsKeys.backgroundLinkEnabled)
        defaults.set(false, forKey: LinkSettingsKeys.lowPowerModeEnabled)

        XCTAssertEqual(
            try store.load(),
            LinkSettings(connectionAvailability: .continueInBackground, locationUpdates: .bestAccuracy)
        )
    }

    func testSavingSettingsPreservesUnknownDefaults() throws {
        let store = UserDefaultsLinkSettingsStore(defaults: defaults)
        defaults.set("keep-me", forKey: "futureSetting")
        defaults.set("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", forKey: "rememberedPeripheralID")

        try store.save(LinkSettings(connectionAvailability: .continueInBackground, locationUpdates: .bestAccuracy))

        XCTAssertTrue(defaults.bool(forKey: LinkSettingsKeys.backgroundLinkEnabled))
        XCTAssertFalse(defaults.bool(forKey: LinkSettingsKeys.lowPowerModeEnabled))
        XCTAssertEqual(defaults.string(forKey: "futureSetting"), "keep-me")
        XCTAssertEqual(
            defaults.string(forKey: "rememberedPeripheralID"),
            "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        )
    }

    func testDraftCancelRestoresOriginalWithoutPersisting() throws {
        let store = FakeSettingsStore(settings: .default)
        var draft = LinkSettingsDraft(current: .default)
        draft.value = LinkSettings(connectionAvailability: .continueInBackground, locationUpdates: .bestAccuracy)

        draft.cancel()

        XCTAssertEqual(draft.value, .default)
        XCTAssertFalse(draft.hasChanges)
        XCTAssertTrue(store.saved.isEmpty)
    }

    func testSettingsExposeConcreteEffectPreview() {
        let settings = LinkSettings(connectionAvailability: .continueInBackground, locationUpdates: .bestAccuracy)

        XCTAssertEqual(settings.summary, "Background · Best Accuracy")
        XCTAssertTrue(settings.effectPreview.contains("30 seconds"))
        XCTAssertTrue(settings.effectPreview.contains("Always Location"))
    }
}

final class GeotaggingViewStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    func testIdlePrioritizesStartAction() {
        let state = GeotaggingViewState.make(from: .fixture(cameraState: .idle), now: now)

        XCTAssertEqual(state.phase, .notConnected)
        XCTAssertEqual(state.title, "Not Connected")
        XCTAssertEqual(state.primaryAction, .start)
        XCTAssertEqual(state.primaryActionLabel, "Start Geotagging")
    }

    func testLinkedIsNotReadyUntilFirstPacketSucceeds() {
        let state = GeotaggingViewState.make(
            from: .fixture(cameraState: .linked, packetsSent: 0, hasLocation: true),
            now: now
        )

        XCTAssertEqual(state.phase, .sendingFirstLocation)
        XCTAssertNotEqual(state.title, "Ready to Geotag")
        XCTAssertEqual(state.primaryAction, .stop)
    }

    func testSuccessfulPacketMakesSessionReady() {
        let state = GeotaggingViewState.make(
            from: .fixture(
                cameraState: .linked,
                packetsSent: 1,
                lastSentAt: now.addingTimeInterval(-12),
                hasLocation: true,
                horizontalAccuracy: 8
            ),
            now: now
        )

        XCTAssertEqual(state.phase, .ready)
        XCTAssertEqual(state.title, "Ready to Geotag")
        XCTAssertEqual(state.lastUpdateText, "12 seconds ago")
        XCTAssertEqual(state.readiness.first(where: { $0.title == "iPhone Location" })?.detail, "Ready · ±8 m")
        XCTAssertEqual(state.secondaryAction, .sendNow)
    }

    func testForegroundConnectionOffersCancel() {
        let state = GeotaggingViewState.make(
            from: .fixture(cameraState: .connecting, isForeground: true),
            now: now
        )

        XCTAssertEqual(state.phase, .connecting)
        XCTAssertEqual(state.primaryAction, .cancel)
        XCTAssertTrue(state.showsProgress)
    }

    func testBackgroundReconnectIsWaitingNotInfiniteLoading() {
        let state = GeotaggingViewState.make(
            from: .fixture(
                cameraState: .connecting,
                backgroundEnabled: true,
                isForeground: false,
                pendingReconnectArmed: true
            ),
            now: now
        )

        XCTAssertEqual(state.phase, .waitingInBackground)
        XCTAssertEqual(state.title, "Waiting for Camera")
        XCTAssertFalse(state.showsProgress)
        XCTAssertNil(state.primaryAction)
    }

    func testDeniedPermissionOffersRecoveryWithoutStarting() {
        let state = GeotaggingViewState.make(
            from: .fixture(cameraState: .idle, locationPermission: .denied, transientError: "Location access is off."),
            now: now
        )

        XCTAssertEqual(state.phase, .needsAttention)
        XCTAssertEqual(state.primaryAction, .openSettings)
        XCTAssertEqual(state.primaryActionLabel, "Review Location Permission")
    }

    func testFailureKeepsLastSuccessfulUpdateAndOffersRetry() {
        let state = GeotaggingViewState.make(
            from: .fixture(
                cameraState: .failed,
                packetsSent: 2,
                lastSentAt: now.addingTimeInterval(-90),
                transientError: "Camera connection timed out."
            ),
            now: now
        )

        XCTAssertEqual(state.phase, .needsAttention)
        XCTAssertEqual(state.primaryAction, .retry)
        XCTAssertEqual(state.lastUpdateText, "1 minute ago")
        XCTAssertEqual(state.message, "Camera connection timed out.")
    }

    func testConnectedWithoutLocationWaitsWithoutFalseReadiness() {
        let state = GeotaggingViewState.make(
            from: .fixture(cameraState: .linked, packetsSent: 0, hasLocation: false),
            now: now
        )

        XCTAssertEqual(state.phase, .waitingForLocation)
        XCTAssertEqual(state.primaryAction, .stop)
        XCTAssertFalse(state.showsProgress)
    }

    func testStaleSuccessfulUpdateBecomesActionableDegradedState() {
        let state = GeotaggingViewState.make(
            from: .fixture(
                cameraState: .linked,
                packetsSent: 1,
                lastSentAt: now.addingTimeInterval(-301),
                hasLocation: true
            ),
            now: now
        )

        XCTAssertEqual(state.phase, .needsAttention)
        XCTAssertEqual(state.title, "Location Update Delayed")
        XCTAssertEqual(state.primaryAction, .sendNow)
    }

    func testStoppedStateOffersStartAgain() {
        let state = GeotaggingViewState.make(from: .fixture(cameraState: .stopped), now: now)

        XCTAssertEqual(state.phase, .stopped)
        XCTAssertEqual(state.primaryAction, .start)
        XCTAssertEqual(state.primaryActionLabel, "Start Geotagging")
    }

    func testExperimentalProfileRequiresExplicitContinueAndOffersCancel() {
        let state = GeotaggingViewState.make(
            from: .fixture(cameraState: .awaitingApproval, hasLocation: true),
            now: now
        )

        XCTAssertEqual(state.phase, .approvalRequired)
        XCTAssertEqual(state.primaryAction, .approveExperimental)
        XCTAssertEqual(state.secondaryAction, .cancel)
        XCTAssertTrue(state.message.contains("Experimental") || state.title.contains("Experimental"))
    }

    func testUnsupportedProfileShowsReasonAndSafeCancel() {
        let state = GeotaggingViewState.make(
            from: .fixture(cameraState: .unsupported, transientError: "DD11 lacks write-with-response."),
            now: now
        )

        XCTAssertEqual(state.phase, .unsupported)
        XCTAssertEqual(state.primaryAction, .cancel)
        XCTAssertEqual(state.message, "DD11 lacks write-with-response.")
    }

    func testBackgroundPermissionIsPartialRatherThanReady() {
        let state = GeotaggingViewState.make(
            from: .fixture(
                cameraState: .linked,
                packetsSent: 1,
                lastSentAt: now,
                locationPermission: .whenInUse,
                hasLocation: true,
                backgroundEnabled: true
            ),
            now: now
        )

        XCTAssertEqual(state.phase, .ready)
        XCTAssertEqual(state.notice, "Background Permission Needed")
        XCTAssertEqual(state.noticeAction, .requestBackgroundPermission)
    }
}

@MainActor
final class CameraGPSLinkAppModelTests: XCTestCase {
    func testStartWaitsForPermissionBeforeStartingBLE() {
        let camera = FakeCameraService()
        let location = FakeLocationService(permission: .notDetermined)
        let model = makeModel(camera: camera, location: location)

        model.startGeotagging()

        XCTAssertEqual(location.whenInUseRequests, 1)
        XCTAssertEqual(camera.foregroundStarts, 0)
        XCTAssertEqual(model.viewState.phase, .requestingPermission)

        location.setPermission(.whenInUse)

        XCTAssertEqual(location.starts, 1)
        XCTAssertEqual(camera.foregroundStarts, 1)
    }

    func testAuthorizedPermissionsStartForegroundServices() {
        for permission in [LocationPermission.whenInUse, .always] {
            let camera = FakeCameraService()
            let location = FakeLocationService(permission: permission)
            let model = makeModel(camera: camera, location: location)

            model.startGeotagging()

            XCTAssertEqual(location.starts, 1, "permission: \(permission)")
            XCTAssertEqual(camera.foregroundStarts, 1, "permission: \(permission)")
        }
    }

    func testDeniedPermissionDoesNotStartBLEAndOffersRecovery() {
        let camera = FakeCameraService()
        let location = FakeLocationService(permission: .denied)
        let model = makeModel(camera: camera, location: location)

        model.startGeotagging()

        XCTAssertEqual(camera.foregroundStarts, 0)
        XCTAssertEqual(model.viewState.primaryAction, .openSettings)
    }

    func testRestrictedPermissionDoesNotStartBLE() {
        let camera = FakeCameraService()
        let location = FakeLocationService(permission: .restricted)
        let model = makeModel(camera: camera, location: location)

        model.startGeotagging()

        XCTAssertEqual(camera.foregroundStarts, 0)
        XCTAssertEqual(model.viewState.primaryAction, .openSettings)
    }

    func testReturningFromSettingsClearsResolvedPermissionError() {
        let camera = FakeCameraService()
        let location = FakeLocationService(permission: .denied)
        let model = makeModel(camera: camera, location: location)
        model.startGeotagging()

        location.setPermission(.whenInUse)

        XCTAssertEqual(model.viewState.phase, .notConnected)
        XCTAssertEqual(model.viewState.primaryAction, .start)
        XCTAssertFalse(model.viewState.message.contains("access is off"))
    }

    func testCancellingPendingStartHasNoLaterBLESideEffect() {
        let camera = FakeCameraService()
        let location = FakeLocationService(permission: .notDetermined)
        let model = makeModel(camera: camera, location: location)

        model.startGeotagging()
        model.cancelCurrentAttempt()
        location.setPermission(.whenInUse)

        XCTAssertEqual(camera.foregroundStarts, 0)
        XCTAssertEqual(camera.cancels, 1)
        XCTAssertEqual(location.stops, 1)
    }

    func testDuplicateScenePhaseDoesNotDuplicateBackgroundResume() {
        let settings = LinkSettings(connectionAvailability: .continueInBackground, locationUpdates: .batterySaver)
        let camera = FakeCameraService()
        let location = FakeLocationService(permission: .always)
        let model = makeModel(camera: camera, location: location, settings: settings)
        model.startGeotagging()
        let startsBeforeSceneChange = location.starts

        model.handleScenePhase(isForeground: true)
        model.handleScenePhase(isForeground: true)

        XCTAssertEqual(camera.backgroundResumes, 1)
        XCTAssertEqual(location.starts, startsBeforeSceneChange + 1)
    }

    func testPersistedActiveIntentAllowsBackgroundResumeAfterModelRelaunch() {
        let settings = LinkSettings(connectionAvailability: .continueInBackground, locationUpdates: .batterySaver)
        let camera = FakeCameraService()
        camera.snapshot.activeLinkIntent = true
        let location = FakeLocationService(permission: .always)
        let model = makeModel(camera: camera, location: location, settings: settings)

        model.handleScenePhase(isForeground: false)

        XCTAssertEqual(camera.backgroundResumes, 1)
    }

    func testStopPreventsLaterSceneChangeFromResumingBackgroundLink() {
        let settings = LinkSettings(connectionAvailability: .continueInBackground, locationUpdates: .batterySaver)
        let camera = FakeCameraService()
        let location = FakeLocationService(permission: .always)
        let model = makeModel(camera: camera, location: location, settings: settings)
        model.startGeotagging()
        model.stopGeotagging()

        model.handleScenePhase(isForeground: false)
        model.handleScenePhase(isForeground: true)

        XCTAssertEqual(camera.backgroundResumes, 0)
    }

    func testApplyPublishesAndConfiguresOnlyFinalSettingsOnce() throws {
        let initial = LinkSettings.default
        let updated = LinkSettings(connectionAvailability: .continueInBackground, locationUpdates: .bestAccuracy)
        let store = FakeSettingsStore(settings: initial)
        let camera = FakeCameraService()
        let location = FakeLocationService(permission: .whenInUse)
        let model = makeModel(camera: camera, location: location, settingsStore: store)
        var publications: [LinkSettings] = []
        let token = model.$settings.dropFirst().sink { publications.append($0) }
        let initialCameraConfigurations = camera.configurations.count
        let initialLocationConfigurations = location.configurations.count

        XCTAssertTrue(model.applySettings(updated))

        XCTAssertEqual(publications, [updated])
        XCTAssertEqual(store.saved, [updated])
        XCTAssertEqual(camera.configurations.count, initialCameraConfigurations + 1)
        XCTAssertEqual(location.configurations.count, initialLocationConfigurations + 1)
        XCTAssertEqual(camera.configurations.last, updated)
        XCTAssertEqual(location.configurations.last?.settings, updated)
        withExtendedLifetime(token) {}
    }

    func testApplyFailureKeepsPreviousValidState() {
        let initial = LinkSettings.default
        let updated = LinkSettings(connectionAvailability: .continueInBackground, locationUpdates: .bestAccuracy)
        let store = FakeSettingsStore(settings: initial)
        store.saveError = TestFailure.expected
        let camera = FakeCameraService()
        let location = FakeLocationService(permission: .whenInUse)
        let model = makeModel(camera: camera, location: location, settingsStore: store)
        let initialCameraConfigurations = camera.configurations.count

        XCTAssertFalse(model.applySettings(updated))

        XCTAssertEqual(model.settings, initial)
        XCTAssertEqual(camera.configurations.count, initialCameraConfigurations)
        XCTAssertTrue(model.viewState.message.contains("couldn’t be applied"))
    }

    func testStaleOrInvalidCachedLocationIsNotReportedUsable() {
        let camera = FakeCameraService()
        camera.snapshot.state = .linked
        let location = FakeLocationService(permission: .whenInUse)
        location.snapshot.currentLocation = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 35, longitude: 139),
            altitude: 0,
            horizontalAccuracy: -1,
            verticalAccuracy: 1,
            timestamp: Date(timeIntervalSince1970: 9_990)
        )

        let model = makeModel(camera: camera, location: location)

        XCTAssertEqual(model.viewState.phase, .waitingForLocation)
        XCTAssertFalse(model.viewState.readiness.first(where: { $0.id == "location" })?.isReady ?? true)
    }

    func testTimeDerivedReadinessDegradesWithoutServicePublication() {
        var clock = Date(timeIntervalSince1970: 10_000)
        let camera = FakeCameraService()
        camera.snapshot.state = .linked
        camera.snapshot.packetsSent = 1
        camera.snapshot.lastSentAt = clock
        let location = FakeLocationService(permission: .whenInUse)
        location.snapshot.currentLocation = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 35, longitude: 139),
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            timestamp: clock
        )
        let model = makeModel(camera: camera, location: location, now: { clock })
        XCTAssertEqual(model.viewState.phase, .ready)

        clock = clock.addingTimeInterval(301)
        model.refreshTimeDerivedState()

        XCTAssertNotEqual(model.viewState.phase, .ready)
        XCTAssertFalse(model.viewState.readiness.first(where: { $0.id == "location" })?.isReady ?? true)
    }

    func testBackgroundPermissionRequestIsExplicit() {
        let camera = FakeCameraService()
        let location = FakeLocationService(permission: .whenInUse)
        let model = makeModel(camera: camera, location: location)

        model.requestBackgroundPermission()

        XCTAssertEqual(location.alwaysRequests, 1)
    }

    private func makeModel(
        camera: FakeCameraService,
        location: FakeLocationService,
        settings: LinkSettings = .default,
        settingsStore: FakeSettingsStore? = nil,
        now: @escaping () -> Date = { Date(timeIntervalSince1970: 10_000) }
    ) -> CameraGPSLinkAppModel {
        CameraGPSLinkAppModel(
            cameraService: camera,
            locationService: location,
            settingsStore: settingsStore ?? FakeSettingsStore(settings: settings),
            diagnosticsStore: DiagnosticsLogStore(),
            now: now,
            openSettings: {}
        )
    }
}

@MainActor
private final class FakeCameraService: CameraLinkServicing {
    var onChange: (() -> Void)?
    var snapshot = CameraServiceSnapshot.fixture()
    var configurations: [LinkSettings] = []
    var foregroundStarts = 0
    var backgroundResumes = 0
    var cancels = 0
    var stops = 0
    var sends = 0
    var locationProvider: (() -> CLLocation?)?

    func configure(settings: LinkSettings) { configurations.append(settings) }
    func setLocationProvider(_ provider: @escaping () -> CLLocation?) { locationProvider = provider }
    func startForegroundLink() { foregroundStarts += 1 }
    func resumeBackgroundLink() { backgroundResumes += 1 }
    func cancelCurrentAttempt() { cancels += 1 }
    func approveExperimentalProfile() {}
    func requestPairingInitialization() {}
    func confirmPairingInitialization() {}
    func cancelPairingInitialization() {}
    func stopLink() { stops += 1 }
    func sendLocationNow() { sends += 1 }
    func sendLocationIfDue() {}
}

@MainActor
private final class FakeLocationService: LocationServicing {
    var onChange: (() -> Void)?
    var snapshot: LocationServiceSnapshot
    var configurations: [(settings: LinkSettings, isForeground: Bool)] = []
    var whenInUseRequests = 0
    var alwaysRequests = 0
    var starts = 0
    var stops = 0

    init(permission: LocationPermission) {
        snapshot = LocationServiceSnapshot(
            permission: permission, currentLocation: nil, isUpdating: false, lastError: nil)
    }

    func configure(settings: LinkSettings, isForeground: Bool) {
        configurations.append((settings, isForeground))
    }

    func requestWhenInUseAuthorization() { whenInUseRequests += 1 }
    func requestAlwaysAuthorization() { alwaysRequests += 1 }
    func startUpdating() { starts += 1 }
    func stopUpdating() { stops += 1 }

    func setPermission(_ permission: LocationPermission) {
        snapshot.permission = permission
        onChange?()
    }
}

private final class FakeSettingsStore: LinkSettingsStoring {
    var settings: LinkSettings
    var saved: [LinkSettings] = []
    var saveError: Error?

    init(settings: LinkSettings) {
        self.settings = settings
    }

    func load() throws -> LinkSettings { settings }

    func save(_ settings: LinkSettings) throws {
        if let saveError { throw saveError }
        saved.append(settings)
        self.settings = settings
    }
}

private enum TestFailure: Error {
    case expected
}

extension CameraServiceSnapshot {
    fileprivate static func fixture() -> CameraServiceSnapshot {
        CameraServiceSnapshot(
            state: .idle,
            discoveredCameraName: nil,
            targetName: "ILCE-7CM2",
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
    }
}

extension GeotaggingSnapshot {
    fileprivate static func fixture(
        cameraState: CameraConnectionState,
        packetsSent: Int = 0,
        lastSentAt: Date? = nil,
        locationPermission: LocationPermission = .whenInUse,
        hasLocation: Bool = false,
        horizontalAccuracy: CLLocationAccuracy? = nil,
        backgroundEnabled: Bool = false,
        isForeground: Bool = true,
        pendingReconnectArmed: Bool = false,
        transientError: String? = nil
    ) -> GeotaggingSnapshot {
        GeotaggingSnapshot(
            cameraState: cameraState,
            cameraName: nil,
            targetName: "ILCE-7CM2",
            packetsSent: packetsSent,
            lastSentAt: lastSentAt,
            locationPermission: locationPermission,
            hasLocation: hasLocation,
            horizontalAccuracy: horizontalAccuracy,
            backgroundEnabled: backgroundEnabled,
            isForeground: isForeground,
            pendingReconnectArmed: pendingReconnectArmed,
            transientError: transientError
        )
    }
}
