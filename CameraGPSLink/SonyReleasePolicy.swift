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
    let packetSize: Int
    let evidence: String

    func matches(
        identity: SonyCameraIdentity,
        profile: SonyLocationProfile,
        descriptors: [SonyGattDescriptor]
    ) -> Bool {
        SonyCameraIdentity(
            model: model,
            firmware: firmware,
            protocolVersion: protocolVersion
        ).normalizedModel == identity.normalizedModel
            && identity.firmware == firmware
            && identity.protocolVersion == protocolVersion
            && profile.kind == self.profile
            && SonyReleasePolicy.releaseDescriptorFingerprint(descriptors) == descriptorFingerprint
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
        genericCompatibility: SonyCompatibility
    ) -> SonyReleaseDecision {
        guard profile.isExecutable else {
            return .unsupported(
                SonyReleaseRejection(message: profile.reason, shouldContinueScanning: false)
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
                descriptors: descriptors
            ) {
                return .proceed(
                    SonyReleaseAuthorization(
                        requiresExperimentalApproval: false,
                        expectedPacketSize: entry.packetSize,
                        confidence: .verified
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
                    descriptors: descriptors
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
                    descriptors: descriptors
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
            packetSize: SonyProtocol.locationPacketSizeWithTimezone,
            evidence: "A7C II 2.01 iOS qualification candidate"
        )
    }()

    // Public entries stay empty until the physical iOS write, fresh-photo EXIF, and cleanup gates pass.
    static let verifiedEntries: [SonyReleaseCompatibilityEntry] = []
    static let qualificationEntries = [a7c2QualificationEntry]

    private func matchingEntry(
        in entries: [SonyReleaseCompatibilityEntry],
        identity: SonyCameraIdentity,
        profile: SonyLocationProfile,
        descriptors: [SonyGattDescriptor]
    ) -> SonyReleaseCompatibilityEntry? {
        entries.first { $0.matches(identity: identity, profile: profile, descriptors: descriptors) }
    }
}
