import Foundation

enum SonyGattProperty: String, Codable, Hashable {
    case read
    case write
    case writeWithoutResponse
    case notify
    case indicate
}

struct SonyGattDescriptor: Codable, Equatable, Hashable {
    let serviceUUID: String
    let characteristicUUID: String
    let properties: Set<SonyGattProperty>

    init(serviceUUID: String, characteristicUUID: String, properties: Set<SonyGattProperty>) {
        self.serviceUUID = Self.normalized(serviceUUID)
        self.characteristicUUID = Self.normalized(characteristicUUID)
        self.properties = properties
    }

    private static func normalized(_ uuid: String) -> String {
        let lowercased = uuid.lowercased()
        if lowercased.count == 4 {
            return "0000\(lowercased)-0000-1000-8000-00805f9b34fb"
        }
        return lowercased
    }
}

enum SonyLocationProfileKind: String, Codable, Equatable {
    case modern
    case legacy
    case unsupported
}

struct SonyLocationProfile: Codable, Equatable {
    let kind: SonyLocationProfileKind
    let reason: String
    let protocolVersion: Int?
    let experimental: Bool
    let hasStatusNotifications: Bool
    let hasTimeCorrection: Bool
    let hasAreaAdjustment: Bool

    var isExecutable: Bool { kind != .unsupported }
}

enum SonySupportConfidence: String, Codable, Equatable {
    case verified
    case experimental
    case unsupported
}

struct SonyCameraIdentity: Codable, Equatable {
    let model: String
    let firmware: String?
    let protocolVersion: Int?

    var normalizedModel: String {
        let normalized = model
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "")
        return normalized.hasPrefix("LE-") ? String(normalized.dropFirst(3)) : normalized
    }

    var approvalKey: String {
        "\(normalizedModel)|\(firmware ?? "unknown")|\(protocolVersion.map(String.init) ?? "unknown")"
    }
}

struct SonyCompatibility: Equatable {
    let confidence: SonySupportConfidence
    let evidence: String?
}

struct SonyCompatibilityEntry: Equatable {
    let model: String
    let firmware: String?
    let protocolVersion: Int?
    let profile: SonyLocationProfileKind
    let confidence: SonySupportConfidence
    let evidence: String?
}

struct SonyDD21Mode: Equatable {
    let includeTimezone: Bool
    let packetSize: Int
    let valueHex: String
}

enum SonyDD21Error: Error, LocalizedError, Equatable {
    case wrongLength(Int)
    case wrongPrefix
    case unknownFlags(UInt8)
    case nonzeroReserved

    var errorDescription: String? {
        switch self {
        case let .wrongLength(length):
            "DD21 must be exactly 6 or 7 bytes; received \(length)."
        case .wrongPrefix:
            "DD21 has an unsupported framing prefix."
        case let .unknownFlags(flags):
            "DD21 contains unknown feature flag bits: 0x\(String(format: "%02x", flags))."
        case .nonzeroReserved:
            "DD21 contains non-zero reserved bytes."
        }
    }
}

enum SonyLocationCapabilityResolver {
    static func resolve(
        protocolVersion: Int?,
        descriptors: [SonyGattDescriptor],
        discoveryComplete: Bool,
        registryConfidence: SonySupportConfidence? = nil
    ) -> SonyLocationProfile {
        guard discoveryComplete else {
            return unsupported(protocolVersion, "Sony service discovery is incomplete.")
        }
        guard registryConfidence != .unsupported else {
            return unsupported(protocolVersion, "This exact identity is blocked by the compatibility registry.")
        }
        let location = descriptors.filter { $0.serviceUUID == SonyProtocol.locationServiceUUID.lowercased() }
        var locationDescriptors: [String: SonyGattDescriptor] = [:]
        for descriptor in location {
            guard locationDescriptors[descriptor.characteristicUUID] == nil else {
                return unsupported(
                    protocolVersion,
                    "Duplicate characteristic UUIDs make the Sony location service ambiguous."
                )
            }
            locationDescriptors[descriptor.characteristicUUID] = descriptor
        }
        if let error = coreShapeError(locationDescriptors) {
            return unsupported(protocolVersion, error)
        }
        if let error = controlShapeError(locationDescriptors) {
            return unsupported(protocolVersion, error)
        }

        let hasControls = locationDescriptors[SonyProtocol.locationLockUUID.lowercased()] != nil
            && locationDescriptors[SonyProtocol.locationEnableUUID.lowercased()] != nil
        let optional = optionalCapabilities(locationDescriptors)
        return resolveVersion(
            protocolVersion,
            hasControls: hasControls,
            status: optional.status,
            time: optional.time,
            area: optional.area
        )
    }

    static func parseDD21(_ data: Data) throws -> SonyDD21Mode {
        guard data.count == 6 || data.count == 7 else {
            throw SonyDD21Error.wrongLength(data.count)
        }
        guard Array(data.prefix(4)) == [0x06, 0x10, 0x00, 0x9C] else {
            throw SonyDD21Error.wrongPrefix
        }
        guard data[4] & ~UInt8(0x02) == 0 else {
            throw SonyDD21Error.unknownFlags(data[4])
        }
        guard data.dropFirst(5).allSatisfy({ $0 == 0 }) else {
            throw SonyDD21Error.nonzeroReserved
        }
        let includeTimezone = data[4] & 0x02 == 0x02
        return SonyDD21Mode(
            includeTimezone: includeTimezone,
            packetSize: includeTimezone ? 95 : 91,
            valueHex: SonyProtocol.hex(data)
        )
    }

    static let verifiedCompatibility: [SonyCompatibilityEntry] = []
    static let unsupportedCompatibility: [SonyCompatibilityEntry] = []

    static func compatibility(
        identity: SonyCameraIdentity,
        profile: SonyLocationProfile,
        verifiedEntries: [SonyCompatibilityEntry] = verifiedCompatibility,
        unsupportedEntries: [SonyCompatibilityEntry] = unsupportedCompatibility
    ) -> SonyCompatibility {
        guard profile.isExecutable else {
            return SonyCompatibility(confidence: .unsupported, evidence: nil)
        }
        for entry in unsupportedEntries + verifiedEntries where entryMatches(entry, identity: identity, profile: profile) {
            return SonyCompatibility(confidence: entry.confidence, evidence: entry.evidence)
        }
        return SonyCompatibility(confidence: .experimental, evidence: nil)
    }

    static func descriptorFingerprint(_ descriptors: [SonyGattDescriptor]) -> String {
        descriptors
            .sorted {
                ($0.serviceUUID, $0.characteristicUUID) < ($1.serviceUUID, $1.characteristicUUID)
            }
            .map { descriptor in
                let properties = descriptor.properties.map(\.rawValue).sorted().joined(separator: ",")
                return "\(descriptor.serviceUUID)|\(descriptor.characteristicUUID)|\(properties)"
            }
            .joined(separator: ";")
    }

    private static func entryMatches(
        _ entry: SonyCompatibilityEntry,
        identity: SonyCameraIdentity,
        profile: SonyLocationProfile
    ) -> Bool {
        identity.firmware != nil
            && SonyCameraIdentity(
                model: entry.model,
                firmware: entry.firmware,
                protocolVersion: entry.protocolVersion
            ).normalizedModel == identity.normalizedModel
            && entry.firmware == identity.firmware
            && entry.protocolVersion == identity.protocolVersion
            && entry.profile == profile.kind
    }

    private static func has(
        _ descriptors: [String: SonyGattDescriptor],
        _ uuid: String,
        _ property: SonyGattProperty
    ) -> Bool {
        descriptors[uuid.lowercased()]?.properties.contains(property) == true
    }

    private static func coreShapeError(_ descriptors: [String: SonyGattDescriptor]) -> String? {
        if !has(descriptors, SonyProtocol.locationDataWriteUUID, .write) {
            return descriptors[SonyProtocol.locationDataWriteUUID.lowercased()] == nil
                ? "DD11 is missing from the Sony location service."
                : "DD11 does not support write-with-response."
        }
        if !has(descriptors, SonyProtocol.locationConfigReadUUID, .read) {
            return descriptors[SonyProtocol.locationConfigReadUUID.lowercased()] == nil
                ? "DD21 is missing from the Sony location service."
                : "DD21 is not readable."
        }
        return nil
    }

    private static func controlShapeError(_ descriptors: [String: SonyGattDescriptor]) -> String? {
        let hasDD30 = descriptors[SonyProtocol.locationLockUUID.lowercased()] != nil
        let hasDD31 = descriptors[SonyProtocol.locationEnableUUID.lowercased()] != nil
        if hasDD30 != hasDD31 {
            return "Only one of DD30/DD31 is present."
        }
        if hasDD30,
           !(has(descriptors, SonyProtocol.locationLockUUID, .write)
               && has(descriptors, SonyProtocol.locationEnableUUID, .write)) {
            return "DD30/DD31 must both support write-with-response."
        }
        return nil
    }

    private static func optionalCapabilities(
        _ descriptors: [String: SonyGattDescriptor]
    ) -> (status: Bool, time: Bool, area: Bool) {
        (
            status: has(descriptors, SonyProtocol.locationStatusNotifyUUID, .notify)
                || has(descriptors, SonyProtocol.locationStatusNotifyUUID, .indicate),
            time: has(descriptors, SonyProtocol.timeCorrectionUUID, .read),
            area: has(descriptors, SonyProtocol.areaAdjustmentUUID, .read)
        )
    }

    private static func resolveVersion(
        _ version: Int?,
        hasControls: Bool,
        status: Bool,
        time: Bool,
        area: Bool
    ) -> SonyLocationProfile {
        let optional = (status, time, area)
        guard let version else {
            guard hasControls else {
                return unsupported(nil, "Unknown-version cameras with only the legacy shape are not executable.")
            }
            return profile(
                .modern,
                "Complete modern shape with unknown protocol version; explicit approval is required.",
                nil,
                true,
                optional
            )
        }
        if version >= SonyProtocol.protocolVersionRequiresUnlock {
            guard hasControls else {
                return unsupported(version, "Protocol >= 65 requires writable DD30 and DD31 controls.")
            }
            return profile(.modern, "Protocol >= 65 and complete modern location shape.", version, false, optional)
        }
        guard !hasControls else {
            return unsupported(
                version,
                "Protocol < 65 unexpectedly exposes modern controls; model-specific evidence is required."
            )
        }
        return profile(
            .legacy,
            "Protocol < 65 with complete DD11/DD21 legacy shape and no modern controls.",
            version,
            false,
            optional
        )
    }

    private static func profile(
        _ kind: SonyLocationProfileKind,
        _ reason: String,
        _ version: Int?,
        _ experimental: Bool,
        _ optional: (Bool, Bool, Bool)
    ) -> SonyLocationProfile {
        SonyLocationProfile(
            kind: kind,
            reason: reason,
            protocolVersion: version,
            experimental: experimental,
            hasStatusNotifications: optional.0,
            hasTimeCorrection: optional.1,
            hasAreaAdjustment: optional.2
        )
    }

    private static func unsupported(_ version: Int?, _ reason: String) -> SonyLocationProfile {
        SonyLocationProfile(
            kind: .unsupported,
            reason: reason,
            protocolVersion: version,
            experimental: false,
            hasStatusNotifications: false,
            hasTimeCorrection: false,
            hasAreaAdjustment: false
        )
    }
}
