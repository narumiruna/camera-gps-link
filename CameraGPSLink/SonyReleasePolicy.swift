import Foundation

enum SonyDistributionMode: Equatable {
    case development
    case qualification
    case publicRelease
}

struct SonyReleaseCompatibilityEntry: Equatable {
    let model: String
    let firmware: String
    let protocolVersion: Int
    let profile: SonyLocationProfileKind
    let descriptorFingerprint: String
    let pairingDescriptorFingerprint: String
    let packetSize: Int
    let evidence: String

    func matchesIdentity(_ identity: SonyCameraIdentity) -> Bool {
        SonyCameraIdentity(
            model: model,
            firmware: firmware,
            protocolVersion: protocolVersion
        ).normalizedModel == identity.normalizedModel
            && identity.firmware == firmware
            && identity.protocolVersion == protocolVersion
    }

    func matches(
        identity: SonyCameraIdentity,
        profile: SonyLocationProfile,
        descriptors: [SonyGattDescriptor],
        requiresPairingEndpoint: Bool
    ) -> Bool {
        matchesIdentity(identity)
            && profile.kind == self.profile
            && SonyReleasePolicy.releaseDescriptorFingerprint(descriptors) == descriptorFingerprint
            && (!requiresPairingEndpoint
                || SonyReleasePolicy.pairingDescriptorFingerprint(descriptors) == pairingDescriptorFingerprint)
    }
}

struct SonyReleaseAuthorization: Equatable {
    let requiresExperimentalApproval: Bool
    let expectedPacketSize: Int?
    let confidence: SonySupportConfidence
}

struct SonyReleaseRejection: Equatable {
    let message: String
    let shouldContinueScanning: Bool
}

enum SonyReleaseDecision: Equatable {
    case proceed(SonyReleaseAuthorization)
    case unsupported(SonyReleaseRejection)
}

enum SonyReleasePolicyError: Error, LocalizedError, Equatable {
    case packetSizeMismatch(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .packetSizeMismatch(let expected, let actual):
            "This camera selected a \(actual)-byte DD11 packet; this build requires \(expected) bytes."
        }
    }
}

struct SonyReleasePolicy: Equatable {
    let mode: SonyDistributionMode
    let verifiedEntries: [SonyReleaseCompatibilityEntry]
    let qualificationEntries: [SonyReleaseCompatibilityEntry]

    init(
        mode: SonyDistributionMode,
        verifiedEntries: [SonyReleaseCompatibilityEntry] = Self.verifiedEntries,
        qualificationEntries: [SonyReleaseCompatibilityEntry] = Self.qualificationEntries
    ) {
        self.mode = mode
        self.verifiedEntries = verifiedEntries
        self.qualificationEntries = qualificationEntries
    }

    static var current: SonyReleasePolicy {
        #if QUALIFICATION
            SonyReleasePolicy(mode: .qualification)
        #elseif DEBUG
            SonyReleasePolicy(mode: .development)
        #else
            SonyReleasePolicy(mode: .publicRelease)
        #endif
    }

    var allowsExperimentalApproval: Bool {
        mode == .development
    }

    var allowsBackground: Bool {
        mode != .publicRelease
    }

    func evaluate(
        identity: SonyCameraIdentity,
        profile: SonyLocationProfile,
        descriptors: [SonyGattDescriptor],
        genericCompatibility: SonyCompatibility,
        requiresPairingEndpoint: Bool = false
    ) -> SonyReleaseDecision {
        guard profile.isExecutable else {
            return .unsupported(
                SonyReleaseRejection(
                    message: profile.reason,
                    shouldContinueScanning: shouldContinueScanningAfterUnsupportedProfile(identity: identity)
                )
            )
        }
        guard genericCompatibility.confidence != .unsupported else {
            return .unsupported(
                SonyReleaseRejection(
                    message: "This exact camera identity is blocked by the compatibility registry.",
                    shouldContinueScanning: false
                )
            )
        }

        switch mode {
        case .development:
            if let entry = matchingEntry(
                in: verifiedEntries,
                identity: identity,
                profile: profile,
                descriptors: descriptors,
                requiresPairingEndpoint: requiresPairingEndpoint
            ) {
                return .proceed(
                    SonyReleaseAuthorization(
                        requiresExperimentalApproval: false,
                        expectedPacketSize: entry.packetSize,
                        confidence: .verified
                    )
                )
            }
            if let entry = matchingEntry(
                in: qualificationEntries,
                identity: identity,
                profile: profile,
                descriptors: descriptors,
                requiresPairingEndpoint: requiresPairingEndpoint
            ) {
                return .proceed(
                    SonyReleaseAuthorization(
                        requiresExperimentalApproval: false,
                        expectedPacketSize: entry.packetSize,
                        confidence: .experimental
                    )
                )
            }
            return .proceed(
                SonyReleaseAuthorization(
                    requiresExperimentalApproval: true,
                    expectedPacketSize: nil,
                    confidence: .experimental
                )
            )
        case .qualification:
            guard
                let entry = matchingEntry(
                    in: qualificationEntries,
                    identity: identity,
                    profile: profile,
                    descriptors: descriptors,
                    requiresPairingEndpoint: requiresPairingEndpoint
                )
            else {
                return .unsupported(
                    SonyReleaseRejection(
                        message: "This camera does not match the A7C II qualification target.",
                        shouldContinueScanning: true
                    )
                )
            }
            return .proceed(
                SonyReleaseAuthorization(
                    requiresExperimentalApproval: false,
                    expectedPacketSize: entry.packetSize,
                    confidence: .experimental
                )
            )
        case .publicRelease:
            guard
                let entry = matchingEntry(
                    in: verifiedEntries,
                    identity: identity,
                    profile: profile,
                    descriptors: descriptors,
                    requiresPairingEndpoint: requiresPairingEndpoint
                )
            else {
                return .unsupported(
                    SonyReleaseRejection(
                        message: "This camera identity is not supported by this public release.",
                        shouldContinueScanning: true
                    )
                )
            }
            return .proceed(
                SonyReleaseAuthorization(
                    requiresExperimentalApproval: false,
                    expectedPacketSize: entry.packetSize,
                    confidence: .verified
                )
            )
        }
    }

    func validateDD21(_ mode: SonyDD21Mode, authorization: SonyReleaseAuthorization) throws {
        guard let expected = authorization.expectedPacketSize else { return }
        guard mode.packetSize == expected else {
            throw SonyReleasePolicyError.packetSizeMismatch(expected: expected, actual: mode.packetSize)
        }
    }

    static func releaseDescriptorFingerprint(_ descriptors: [SonyGattDescriptor]) -> String {
        let releaseServices = Set([
            SonyProtocol.cameraControlServiceUUID.lowercased(),
            SonyProtocol.locationServiceUUID.lowercased(),
        ])
        return SonyLocationCapabilityResolver.descriptorFingerprint(
            descriptors.filter { releaseServices.contains($0.serviceUUID) }
        )
    }

    static func pairingDescriptorFingerprint(_ descriptors: [SonyGattDescriptor]) -> String {
        SonyLocationCapabilityResolver.descriptorFingerprint(
            descriptors.filter { $0.serviceUUID == SonyProtocol.pairingServiceUUID.lowercased() }
        )
    }

    static let a7c2QualificationEntry: SonyReleaseCompatibilityEntry = {
        let descriptors = [
            SonyGattDescriptor(
                serviceUUID: SonyProtocol.cameraControlServiceUUID,
                characteristicUUID: SonyProtocol.firmwareVersionUUID,
                properties: [.read]
            ),
            SonyGattDescriptor(
                serviceUUID: SonyProtocol.cameraControlServiceUUID,
                characteristicUUID: SonyProtocol.cameraModelUUID,
                properties: [.read]
            ),
            SonyGattDescriptor(
                serviceUUID: SonyProtocol.locationServiceUUID,
                characteristicUUID: SonyProtocol.locationStatusNotifyUUID,
                properties: [.notify]
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
            SonyGattDescriptor(
                serviceUUID: SonyProtocol.locationServiceUUID,
                characteristicUUID: SonyProtocol.locationLockUUID,
                properties: [.read, .write]
            ),
            SonyGattDescriptor(
                serviceUUID: SonyProtocol.locationServiceUUID,
                characteristicUUID: SonyProtocol.locationEnableUUID,
                properties: [.read, .write]
            ),
            SonyGattDescriptor(
                serviceUUID: SonyProtocol.locationServiceUUID,
                characteristicUUID: SonyProtocol.timeCorrectionUUID,
                properties: [.read, .write]
            ),
            SonyGattDescriptor(
                serviceUUID: SonyProtocol.locationServiceUUID,
                characteristicUUID: SonyProtocol.areaAdjustmentUUID,
                properties: [.read, .write]
            ),
        ]
        return SonyReleaseCompatibilityEntry(
            model: "ILCE-7CM2",
            firmware: "2.01",
            protocolVersion: 101,
            profile: .modern,
            descriptorFingerprint: releaseDescriptorFingerprint(descriptors),
            pairingDescriptorFingerprint: pairingDescriptorFingerprint([
                SonyGattDescriptor(
                    serviceUUID: SonyProtocol.pairingServiceUUID,
                    characteristicUUID: SonyProtocol.pairingInitUUID,
                    properties: [.write]
                )
            ]),
            packetSize: SonyProtocol.locationPacketSizeWithTimezone,
            evidence: "docs/compatibility/ilce-7cm2-2.01.md, iOS QUALIFICATION 2026-09-12"
        )
    }()

    // Keep this registry limited to exact identities with physical Release-equivalent evidence.
    static let verifiedEntries = [a7c2QualificationEntry]
    static let qualificationEntries = [a7c2QualificationEntry]

    private func matchingEntry(
        in entries: [SonyReleaseCompatibilityEntry],
        identity: SonyCameraIdentity,
        profile: SonyLocationProfile,
        descriptors: [SonyGattDescriptor],
        requiresPairingEndpoint: Bool
    ) -> SonyReleaseCompatibilityEntry? {
        entries.first {
            $0.matches(
                identity: identity,
                profile: profile,
                descriptors: descriptors,
                requiresPairingEndpoint: requiresPairingEndpoint
            )
        }
    }

    private func shouldContinueScanningAfterUnsupportedProfile(identity: SonyCameraIdentity) -> Bool {
        let exactEntries: [SonyReleaseCompatibilityEntry]
        switch mode {
        case .development:
            return false
        case .qualification:
            exactEntries = qualificationEntries
        case .publicRelease:
            exactEntries = verifiedEntries
        }
        return !exactEntries.contains { $0.matchesIdentity(identity) }
    }
}
