import Foundation

enum ConnectionHealthPolicy {
    static let cameraUpdateMaximumAge: TimeInterval = 5 * 60
    static let locationFixMaximumAge: TimeInterval = 2 * 60
    static let locationFixMaximumFutureSkew: TimeInterval = 10
    static let lowAccuracyThreshold = 100.0
    static let disconnectDebounce: TimeInterval = 10

    static func isLocationFresh(_ timestamp: Date, relativeTo now: Date) -> Bool {
        let age = now.timeIntervalSince(timestamp)
        return age >= -locationFixMaximumFutureSkew && age <= locationFixMaximumAge
    }
}

enum CameraUpdateHealth: Equatable {
    case missing
    case fresh(age: TimeInterval)
    case stale(age: TimeInterval)

    var isFresh: Bool {
        if case .fresh = self { return true }
        return false
    }

    var diagnosticLabel: String {
        switch self {
        case .missing:
            "No confirmed update"
        case .fresh(let age):
            "Fresh (age \(Self.wholeSeconds(age))s)"
        case .stale(let age):
            "Stale (age \(Self.wholeSeconds(age))s)"
        }
    }

    private static func wholeSeconds(_ value: TimeInterval) -> Int {
        max(0, Int(value.rounded(.down)))
    }
}

enum LocationFixHealth: Equatable {
    case missing
    case invalid
    case future(skew: TimeInterval)
    case stale(age: TimeInterval)
    case lowAccuracy(meters: Double, age: TimeInterval)
    case healthy(meters: Double, age: TimeInterval)

    var isWritable: Bool {
        switch self {
        case .lowAccuracy, .healthy:
            true
        default:
            false
        }
    }

    var isReady: Bool {
        if case .healthy = self { return true }
        return false
    }

    var diagnosticLabel: String {
        switch self {
        case .missing:
            "No fix"
        case .invalid:
            "Invalid fix"
        case .future(let skew):
            "Future fix (skew \(Self.wholeSeconds(skew))s)"
        case .stale(let age):
            "Stale fix (age \(Self.wholeSeconds(age))s)"
        case .lowAccuracy(let meters, let age):
            "Low accuracy (±\(Int(meters.rounded())) m, age \(Self.wholeSeconds(age))s)"
        case .healthy(let meters, let age):
            "Healthy (±\(Int(meters.rounded())) m, age \(Self.wholeSeconds(age))s)"
        }
    }

    private static func wholeSeconds(_ value: TimeInterval) -> Int {
        max(0, Int(value.rounded(.down)))
    }
}

struct ConnectionHealth: Equatable {
    let cameraUpdate: CameraUpdateHealth
    let locationFix: LocationFixHealth

    var diagnosticLabel: String {
        "Camera: \(cameraUpdate.diagnosticLabel); iPhone: \(locationFix.diagnosticLabel)"
    }
}

enum ConnectionHealthEvaluator {
    static func evaluate(
        packetsSent: Int,
        lastSentAt: Date?,
        locationTimestamp: Date?,
        horizontalAccuracy: Double?,
        now: Date
    ) -> ConnectionHealth {
        ConnectionHealth(
            cameraUpdate: cameraUpdate(packetsSent: packetsSent, lastSentAt: lastSentAt, now: now),
            locationFix: locationFix(
                timestamp: locationTimestamp,
                horizontalAccuracy: horizontalAccuracy,
                now: now
            )
        )
    }

    static func cameraUpdate(packetsSent: Int, lastSentAt: Date?, now: Date) -> CameraUpdateHealth {
        guard packetsSent > 0, let lastSentAt else { return .missing }
        let age = max(0, now.timeIntervalSince(lastSentAt))
        if age <= ConnectionHealthPolicy.cameraUpdateMaximumAge {
            return .fresh(age: age)
        }
        return .stale(age: age)
    }

    static func locationFix(
        timestamp: Date?,
        horizontalAccuracy: Double?,
        now: Date
    ) -> LocationFixHealth {
        guard let timestamp, let horizontalAccuracy else { return .missing }
        guard horizontalAccuracy.isFinite, horizontalAccuracy >= 0 else { return .invalid }

        let age = now.timeIntervalSince(timestamp)
        if age < -ConnectionHealthPolicy.locationFixMaximumFutureSkew {
            return .future(skew: -age)
        }
        if age > ConnectionHealthPolicy.locationFixMaximumAge {
            return .stale(age: age)
        }
        if horizontalAccuracy > ConnectionHealthPolicy.lowAccuracyThreshold {
            return .lowAccuracy(meters: horizontalAccuracy, age: age)
        }
        return .healthy(meters: horizontalAccuracy, age: age)
    }
}
