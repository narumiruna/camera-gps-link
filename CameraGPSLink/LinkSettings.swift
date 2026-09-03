import Foundation

enum ConnectionAvailability: String, CaseIterable, Identifiable {
    case whileAppIsOpen
    case continueInBackground

    var id: Self { self }

    static func availableOptions(allowsBackground: Bool) -> [ConnectionAvailability] {
        allowsBackground ? allCases : [.whileAppIsOpen]
    }

    var label: String {
        switch self {
        case .whileAppIsOpen:
            "While App Is Open"
        case .continueInBackground:
            "Continue in Background"
        }
    }
}

enum LocationUpdateMode: String, CaseIterable, Identifiable {
    case batterySaver
    case bestAccuracy

    var id: Self { self }

    var label: String {
        switch self {
        case .batterySaver:
            "Battery Saver"
        case .bestAccuracy:
            "Best Accuracy"
        }
    }
}

struct LinkSettings: Equatable {
    var connectionAvailability: ConnectionAvailability
    var locationUpdates: LocationUpdateMode
    var healthAlertsEnabled: Bool

    init(
        connectionAvailability: ConnectionAvailability,
        locationUpdates: LocationUpdateMode,
        healthAlertsEnabled: Bool = false
    ) {
        self.connectionAvailability = connectionAvailability
        self.locationUpdates = locationUpdates
        self.healthAlertsEnabled = healthAlertsEnabled
    }

    static let `default` = LinkSettings(
        connectionAvailability: .whileAppIsOpen,
        locationUpdates: .batterySaver,
        healthAlertsEnabled: false
    )

    var backgroundLinkEnabled: Bool {
        connectionAvailability == .continueInBackground
    }

    var lowPowerModeEnabled: Bool {
        locationUpdates == .batterySaver
    }

    var summary: String {
        let availability = backgroundLinkEnabled ? "Background" : "While Open"
        return "\(availability) · \(locationUpdates.label)"
    }

    func restrictingBackground(to isAllowed: Bool) -> LinkSettings {
        guard !isAllowed, backgroundLinkEnabled else { return self }
        var restricted = self
        restricted.connectionAvailability = .whileAppIsOpen
        return restricted
    }

    var effectPreview: String {
        let delivery =
            switch connectionAvailability {
            case .whileAppIsOpen:
                "Runs only while Camera GPS Link is open."
            case .continueInBackground:
                "Keeps reconnecting when possible and requires Always Location permission. "
                    + "iOS may pause it after force-quit."
            }
        let updates =
            switch locationUpdates {
            case .batterySaver:
                "Uses approximate 100 m location and sends about every 2 minutes."
            case .bestAccuracy:
                "Uses the best available GPS accuracy and sends about every 30 seconds, using more battery."
            }
        let alerts =
            healthAlertsEnabled
            ? "Health Alerts are on and require notification permission."
            : "Health Alerts are off."
        return "\(delivery) \(updates) \(alerts)"
    }
}

struct LinkSettingsDraft: Equatable {
    let original: LinkSettings
    var value: LinkSettings

    init(current: LinkSettings) {
        original = current
        value = current
    }

    var hasChanges: Bool {
        value != original
    }

    mutating func cancel() {
        value = original
    }
}

enum LinkSettingsKeys {
    static let backgroundLinkEnabled = "backgroundLinkEnabled"
    static let lowPowerModeEnabled = "lowPowerModeEnabled"
    static let healthAlertsEnabled = "healthAlertsEnabled"
}

protocol LinkSettingsStoring {
    func load() throws -> LinkSettings
    func save(_ settings: LinkSettings) throws
}

struct UserDefaultsLinkSettingsStore: LinkSettingsStoring {
    let defaults: UserDefaults
    let allowsBackground: Bool

    init(
        defaults: UserDefaults = .standard,
        allowsBackground: Bool = SonyReleasePolicy.current.allowsBackground
    ) {
        self.defaults = defaults
        self.allowsBackground = allowsBackground
    }

    func load() throws -> LinkSettings {
        let storedBackground = defaults.object(forKey: LinkSettingsKeys.backgroundLinkEnabled) as? Bool ?? false
        let backgroundEnabled = storedBackground && allowsBackground
        if storedBackground && !allowsBackground {
            defaults.set(false, forKey: LinkSettingsKeys.backgroundLinkEnabled)
        }
        let lowPowerEnabled = defaults.object(forKey: LinkSettingsKeys.lowPowerModeEnabled) as? Bool ?? true
        let healthAlertsEnabled = defaults.object(forKey: LinkSettingsKeys.healthAlertsEnabled) as? Bool ?? false
        return LinkSettings(
            connectionAvailability: backgroundEnabled ? .continueInBackground : .whileAppIsOpen,
            locationUpdates: lowPowerEnabled ? .batterySaver : .bestAccuracy,
            healthAlertsEnabled: healthAlertsEnabled
        )
    }

    func save(_ settings: LinkSettings) throws {
        let restricted = settings.restrictingBackground(to: allowsBackground)
        defaults.set(restricted.backgroundLinkEnabled, forKey: LinkSettingsKeys.backgroundLinkEnabled)
        defaults.set(restricted.lowPowerModeEnabled, forKey: LinkSettingsKeys.lowPowerModeEnabled)
        defaults.set(restricted.healthAlertsEnabled, forKey: LinkSettingsKeys.healthAlertsEnabled)
    }
}
