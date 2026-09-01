import XCTest

@testable import CameraGPSLink

final class SonyReleasePolicyTests: XCTestCase {
    func testQualificationAcceptsOnlyExactCandidateWithoutExperimentalApproval() {
        let fixture = makeCandidate()
        let policy = SonyReleasePolicy(mode: .qualification)

        let decision = policy.evaluate(
            identity: fixture.identity,
            profile: fixture.profile,
            descriptors: fixture.descriptors,
            genericCompatibility: SonyCompatibility(confidence: .experimental, evidence: nil)
        )

        guard case .proceed(let authorization) = decision else {
            return XCTFail("Exact qualification candidate should proceed")
        }
        XCTAssertFalse(authorization.requiresExperimentalApproval)
        XCTAssertEqual(authorization.expectedPacketSize, 95)
        XCTAssertEqual(authorization.confidence, .experimental)
        XCTAssertFalse(policy.allowsExperimentalApproval)
    }

    func testQualificationRejectsEveryExactMatchDimension() {
        let fixture = makeCandidate()
        let policy = SonyReleasePolicy(mode: .qualification)
        let compatibility = SonyCompatibility(confidence: .experimental, evidence: nil)
        let mismatchedIdentities = [
            SonyCameraIdentity(model: "ILCE-7M4", firmware: "2.01", protocolVersion: 101),
            SonyCameraIdentity(model: "ILCE-7CM2", firmware: "2.02", protocolVersion: 101),
            SonyCameraIdentity(model: "ILCE-7CM2", firmware: nil, protocolVersion: 101),
            SonyCameraIdentity(model: "ILCE-7CM2", firmware: "2.01", protocolVersion: 100),
            SonyCameraIdentity(model: "ILCE-7CM2", firmware: "2.01", protocolVersion: nil),
        ]

        for identity in mismatchedIdentities {
            assertUnsupported(
                policy.evaluate(
                    identity: identity,
                    profile: fixture.profile,
                    descriptors: fixture.descriptors,
                    genericCompatibility: compatibility
                ),
                shouldContinueScanning: true
            )
        }

        let wrongProfile = SonyLocationProfile(
            kind: .legacy,
            reason: "fixture",
            protocolVersion: 101,
            experimental: false,
            hasStatusNotifications: true,
            hasTimeCorrection: true,
            hasAreaAdjustment: true
        )
        assertUnsupported(
            policy.evaluate(
                identity: fixture.identity,
                profile: wrongProfile,
                descriptors: fixture.descriptors,
                genericCompatibility: compatibility
            ),
            shouldContinueScanning: true
        )

        var wrongDescriptors = fixture.descriptors
        wrongDescriptors.removeLast()
        assertUnsupported(
            policy.evaluate(
                identity: fixture.identity,
                profile: fixture.profile,
                descriptors: wrongDescriptors,
                genericCompatibility: compatibility
            ),
            shouldContinueScanning: true
        )

        let structurallyUnsupported = SonyLocationProfile(
            kind: .unsupported,
            reason: "missing required characteristic",
            protocolVersion: 101,
            experimental: false,
            hasStatusNotifications: false,
            hasTimeCorrection: false,
            hasAreaAdjustment: false
        )
        assertUnsupported(
            policy.evaluate(
                identity: fixture.identity,
                profile: structurallyUnsupported,
                descriptors: fixture.descriptors,
                genericCompatibility: compatibility
            ),
            shouldContinueScanning: false
        )
        assertUnsupported(
            policy.evaluate(
                identity: SonyCameraIdentity(model: "ILCE-7M4", firmware: "4.00", protocolVersion: 101),
                profile: structurallyUnsupported,
                descriptors: fixture.descriptors,
                genericCompatibility: compatibility
            ),
            shouldContinueScanning: true
        )
    }

    func testPublicReleaseRejectsCandidateUntilVerifiedRegistryPromotion() {
        let fixture = makeCandidate()
        let policy = SonyReleasePolicy(mode: .publicRelease)

        let compatibility = SonyCompatibility(confidence: .experimental, evidence: nil)
        assertUnsupported(
            policy.evaluate(
                identity: fixture.identity,
                profile: fixture.profile,
                descriptors: fixture.descriptors,
                genericCompatibility: compatibility
            ),
            shouldContinueScanning: true
        )
        let unsupportedProfile = SonyLocationProfile(
            kind: .unsupported,
            reason: "missing required characteristic",
            protocolVersion: 101,
            experimental: false,
            hasStatusNotifications: false,
            hasTimeCorrection: false,
            hasAreaAdjustment: false
        )
        assertUnsupported(
            policy.evaluate(
                identity: fixture.identity,
                profile: unsupportedProfile,
                descriptors: fixture.descriptors,
                genericCompatibility: compatibility
            ),
            shouldContinueScanning: true
        )
        XCTAssertTrue(policy.verifiedEntries.isEmpty)
        XCTAssertFalse(policy.allowsExperimentalApproval)
        XCTAssertFalse(policy.allowsBackground)
    }

    func testPromotedPublicEntryProceedsAsVerified() {
        let fixture = makeCandidate()
        let entry = SonyReleasePolicy.a7c2QualificationEntry
        let policy = SonyReleasePolicy(mode: .publicRelease, verifiedEntries: [entry])

        let decision = policy.evaluate(
            identity: fixture.identity,
            profile: fixture.profile,
            descriptors: fixture.descriptors,
            genericCompatibility: SonyCompatibility(confidence: .experimental, evidence: nil)
        )

        guard case .proceed(let authorization) = decision else {
            return XCTFail("Promoted exact entry should proceed")
        }
        XCTAssertEqual(authorization.confidence, .verified)
        XCTAssertFalse(authorization.requiresExperimentalApproval)
        XCTAssertEqual(authorization.expectedPacketSize, 95)
    }

    func testDevelopmentKeepsVolatileExperimentalApproval() {
        let fixture = makeCandidate()
        let decision = SonyReleasePolicy(mode: .development).evaluate(
            identity: fixture.identity,
            profile: fixture.profile,
            descriptors: fixture.descriptors,
            genericCompatibility: SonyCompatibility(confidence: .experimental, evidence: nil)
        )

        guard case .proceed(let authorization) = decision else {
            return XCTFail("Development fixture should reach approval")
        }
        XCTAssertTrue(authorization.requiresExperimentalApproval)
        XCTAssertNil(authorization.expectedPacketSize)
        XCTAssertTrue(SonyReleasePolicy(mode: .development).allowsExperimentalApproval)
    }

    func testQualificationPairingRequiresExactEE01EndpointShape() {
        let policy = SonyReleasePolicy(mode: .qualification)
        let locationFixture = makeCandidate()
        let pairingFixture = makeCandidate(includePairing: true)
        let compatibility = SonyCompatibility(confidence: .experimental, evidence: nil)

        guard
            case .proceed = policy.evaluate(
                identity: locationFixture.identity,
                profile: locationFixture.profile,
                descriptors: locationFixture.descriptors,
                genericCompatibility: compatibility
            )
        else {
            return XCTFail("Location authorization must not depend on the pairing service")
        }
        guard
            case .proceed = policy.evaluate(
                identity: pairingFixture.identity,
                profile: pairingFixture.profile,
                descriptors: pairingFixture.descriptors,
                genericCompatibility: compatibility,
                requiresPairingEndpoint: true
            )
        else {
            return XCTFail("Evidence-backed EE01 pairing shape should proceed")
        }

        assertUnsupported(
            policy.evaluate(
                identity: locationFixture.identity,
                profile: locationFixture.profile,
                descriptors: locationFixture.descriptors,
                genericCompatibility: compatibility,
                requiresPairingEndpoint: true
            ),
            shouldContinueScanning: true
        )
        var wrongPairingDescriptors = locationFixture.descriptors
        wrongPairingDescriptors.append(
            descriptor(
                SonyProtocol.pairingInitUUID,
                [.writeWithoutResponse],
                service: SonyProtocol.pairingServiceUUID
            )
        )
        assertUnsupported(
            policy.evaluate(
                identity: locationFixture.identity,
                profile: locationFixture.profile,
                descriptors: wrongPairingDescriptors,
                genericCompatibility: compatibility,
                requiresPairingEndpoint: true
            ),
            shouldContinueScanning: true
        )
    }

    func testExactPolicyRejectsDifferentDD21PacketSize() throws {
        let authorization = SonyReleaseAuthorization(
            requiresExperimentalApproval: false,
            expectedPacketSize: 95,
            confidence: .experimental
        )
        let policy = SonyReleasePolicy(mode: .qualification)
        let mode95 = try SonyLocationCapabilityResolver.parseDD21(
            Data([0x06, 0x10, 0x00, 0x9C, 0x02, 0x00, 0x00])
        )
        let mode91 = try SonyLocationCapabilityResolver.parseDD21(
            Data([0x06, 0x10, 0x00, 0x9C, 0x00, 0x00, 0x00])
        )

        XCTAssertNoThrow(try policy.validateDD21(mode95, authorization: authorization))
        XCTAssertThrowsError(try policy.validateDD21(mode91, authorization: authorization))
    }

    @MainActor
    func testPublicReleaseRejectsLocationAndPairingBeforeAnyOperation() {
        for intent in [CameraConnectionIntent.location, .pairing] {
            let fixture = makeCandidate(includePairing: true)
            let manager = makeManager(policy: SonyReleasePolicy(mode: .publicRelease))
            manager.activeSessionRequested = true
            manager.connectionIntent = intent
            manager.discoveredCameraName = fixture.identity.model
            manager.detectedFirmware = fixture.identity.firmware
            manager.advertisementProtocolVersion = fixture.identity.protocolVersion
            manager.descriptors = fixture.descriptors

            manager.resolveDiscoveredProfile()

            XCTAssertEqual(manager.state, .unsupported)
            XCTAssertTrue(manager.operationQueue.isEmpty)
            XCTAssertTrue(manager.sanitizedOperationOrder.isEmpty)
            XCTAssertFalse(manager.experimentalApprovalPending)
            XCTAssertFalse(manager.pairingConfirmationPending)
        }
    }

    @MainActor
    func testQualificationLocationAndPairingBeginWithReadOnlyDD21Preflight() {
        let missingPairingEndpoint = makeCandidate()
        let rejectedPairingManager = makeManager(policy: SonyReleasePolicy(mode: .qualification))
        rejectedPairingManager.activeSessionRequested = true
        rejectedPairingManager.connectionIntent = .pairing
        rejectedPairingManager.discoveredCameraName = missingPairingEndpoint.identity.model
        rejectedPairingManager.detectedFirmware = missingPairingEndpoint.identity.firmware
        rejectedPairingManager.advertisementProtocolVersion = missingPairingEndpoint.identity.protocolVersion
        rejectedPairingManager.descriptors = missingPairingEndpoint.descriptors

        rejectedPairingManager.resolveDiscoveredProfile()

        XCTAssertEqual(rejectedPairingManager.state, .unsupported)
        XCTAssertTrue(rejectedPairingManager.sanitizedOperationOrder.isEmpty)

        for intent in [CameraConnectionIntent.location, .pairing] {
            let fixture = makeCandidate(includePairing: true)
            let manager = makeManager(policy: SonyReleasePolicy(mode: .qualification))
            manager.activeSessionRequested = true
            manager.connectionIntent = intent
            manager.discoveredCameraName = fixture.identity.model
            manager.detectedFirmware = fixture.identity.firmware
            manager.advertisementProtocolVersion = fixture.identity.protocolVersion
            manager.descriptors = fixture.descriptors

            manager.resolveDiscoveredProfile()

            XCTAssertEqual(manager.sanitizedOperationOrder, ["DD21 preflight"])
            XCTAssertFalse(manager.sanitizedOperationOrder.contains("DD01 notify"))
            XCTAssertFalse(manager.sanitizedOperationOrder.contains("DD30 lock"))
            XCTAssertFalse(manager.sanitizedOperationOrder.contains("DD31 enable"))
            XCTAssertFalse(manager.sanitizedOperationOrder.contains("DD11 location"))
            XCTAssertFalse(manager.sanitizedOperationOrder.contains("EE01 pairing init"))
            XCTAssertFalse(manager.pairingConfirmationPending)
        }
    }

    @MainActor
    func testPublicReleaseForcesBackgroundOffAtStoreAndBLELayers() throws {
        let suite = "SonyReleasePolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: LinkSettingsKeys.backgroundLinkEnabled)
        let store = UserDefaultsLinkSettingsStore(defaults: defaults, allowsBackground: false)

        XCTAssertEqual(try store.load().connectionAvailability, .whileAppIsOpen)
        XCTAssertFalse(defaults.bool(forKey: LinkSettingsKeys.backgroundLinkEnabled))
        XCTAssertEqual(ConnectionAvailability.availableOptions(allowsBackground: false), [.whileAppIsOpen])

        let manager = makeManager(policy: SonyReleasePolicy(mode: .publicRelease))
        manager.configure(backgroundLinkEnabled: true, lowPowerModeEnabled: true)
        XCTAssertFalse(manager.backgroundLinkEnabled)
    }

    private func assertUnsupported(
        _ decision: SonyReleaseDecision,
        shouldContinueScanning: Bool? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .unsupported(let rejection) = decision else {
            return XCTFail("Expected unsupported decision", file: file, line: line)
        }
        if let shouldContinueScanning {
            XCTAssertEqual(
                rejection.shouldContinueScanning,
                shouldContinueScanning,
                file: file,
                line: line
            )
        }
    }

    @MainActor
    private func makeManager(policy: SonyReleasePolicy) -> CameraBLEManager {
        CameraBLEManager(
            diagnosticsStore: DiagnosticsLogStore(),
            timeoutPolicy: ForegroundConnectionTimeoutPolicy(),
            timeoutScheduler: .live,
            identityStore: ReleasePolicyInMemoryIdentityStore(),
            releasePolicy: policy
        )
    }

    private func makeCandidate(includePairing: Bool = false) -> CandidateFixture {
        var descriptors = candidateDescriptors()
        if includePairing {
            descriptors.append(
                SonyGattDescriptor(
                    serviceUUID: SonyProtocol.pairingServiceUUID,
                    characteristicUUID: SonyProtocol.pairingInitUUID,
                    properties: [.write]
                )
            )
        }
        let identity = SonyCameraIdentity(model: "ILCE-7CM2", firmware: "2.01", protocolVersion: 101)
        let profile = SonyLocationCapabilityResolver.resolve(
            protocolVersion: identity.protocolVersion,
            descriptors: descriptors,
            discoveryComplete: true
        )
        return CandidateFixture(identity: identity, profile: profile, descriptors: descriptors)
    }

    private func candidateDescriptors() -> [SonyGattDescriptor] {
        [
            descriptor(SonyProtocol.firmwareVersionUUID, [.read], service: SonyProtocol.cameraControlServiceUUID),
            descriptor(SonyProtocol.cameraModelUUID, [.read], service: SonyProtocol.cameraControlServiceUUID),
            descriptor(SonyProtocol.locationStatusNotifyUUID, [.notify]),
            descriptor(SonyProtocol.locationDataWriteUUID, [.write]),
            descriptor(SonyProtocol.locationConfigReadUUID, [.read]),
            descriptor(SonyProtocol.locationLockUUID, [.read, .write]),
            descriptor(SonyProtocol.locationEnableUUID, [.read, .write]),
            descriptor(SonyProtocol.timeCorrectionUUID, [.read, .write]),
            descriptor(SonyProtocol.areaAdjustmentUUID, [.read, .write]),
        ]
    }

    private func descriptor(
        _ uuid: String,
        _ properties: Set<SonyGattProperty>,
        service: String = SonyProtocol.locationServiceUUID
    ) -> SonyGattDescriptor {
        SonyGattDescriptor(serviceUUID: service, characteristicUUID: uuid, properties: properties)
    }
}

private struct CandidateFixture {
    let identity: SonyCameraIdentity
    let profile: SonyLocationProfile
    let descriptors: [SonyGattDescriptor]
}

private final class ReleasePolicyInMemoryIdentityStore: SonyValidatedIdentityStoring {
    func load() -> SonyValidatedIdentityRecord? { nil }
    func save(_ record: SonyValidatedIdentityRecord) {}
    func clear() {}
}
