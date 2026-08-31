import Foundation

struct SonyValidatedIdentityRecord: Codable, Equatable {
    let peripheralID: String
    let identity: SonyCameraIdentity
    let profile: SonyLocationProfileKind
    let descriptorFingerprint: String

    func matches(
        peripheralID: String,
        identity: SonyCameraIdentity,
        profile: SonyLocationProfile,
        descriptors: [SonyGattDescriptor]
    ) -> Bool {
        self.peripheralID == peripheralID
            && self.identity == identity
            && self.profile == profile.kind
            && descriptorFingerprint == SonyLocationCapabilityResolver.descriptorFingerprint(descriptors)
    }
}

protocol SonyValidatedIdentityStoring {
    func load() -> SonyValidatedIdentityRecord?
    func save(_ record: SonyValidatedIdentityRecord)
    func clear()
}

final class UserDefaultsSonyValidatedIdentityStore: SonyValidatedIdentityStoring {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "validatedSonyLocationIdentity") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> SonyValidatedIdentityRecord? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SonyValidatedIdentityRecord.self, from: data)
    }

    func save(_ record: SonyValidatedIdentityRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}
