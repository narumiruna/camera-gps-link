import Foundation

extension GeotaggingViewState {
    static func resolvedHealth(for snapshot: GeotaggingSnapshot, now: Date) -> ConnectionHealth {
        if let health = snapshot.health { return health }
        let fallbackTimestamp = snapshot.locationTimestamp ?? (snapshot.hasLocation ? now : nil)
        let fallbackAccuracy = snapshot.horizontalAccuracy ?? (snapshot.hasLocation ? 0 : nil)
        return ConnectionHealthEvaluator.evaluate(
            packetsSent: snapshot.packetsSent,
            lastSentAt: snapshot.lastSentAt,
            locationTimestamp: fallbackTimestamp,
            horizontalAccuracy: fallbackAccuracy,
            now: now
        )
    }

    static func notices(
        for snapshot: GeotaggingSnapshot,
        health: ConnectionHealth
    ) -> [StatusNotice] {
        var notices: [StatusNotice] = []
        if snapshot.cameraState == .linked, let notice = locationNotice(for: health.locationFix) {
            notices.append(notice)
        }

        let needsBackgroundPermission =
            snapshot.backgroundEnabled
            && snapshot.locationPermission != .always
            && snapshot.locationPermission.allowsForegroundLocation
        if needsBackgroundPermission {
            notices.append(
                StatusNotice(
                    id: "background-permission",
                    title: "Background Permission Needed",
                    message: "Foreground geotagging still works. Allow Always Location for background updates.",
                    action: .requestBackgroundPermission,
                    actionLabel: "Allow Background Location"
                )
            )
        }
        return notices
    }

    static func locationNotice(for health: LocationFixHealth) -> StatusNotice? {
        switch health {
        case .invalid, .future:
            return StatusNotice(
                id: "location-invalid",
                title: "iPhone Location Needs Attention",
                message: "The current fix cannot be sent. Camera GPS Link will wait for a valid fix.",
                action: nil,
                actionLabel: nil
            )
        case .stale:
            return StatusNotice(
                id: "location-stale",
                title: "iPhone Location Is Stale",
                message: "The camera can use its last confirmed location, but a new update needs a current fix.",
                action: nil,
                actionLabel: nil
            )
        case .lowAccuracy:
            return StatusNotice(
                id: "location-low-accuracy",
                title: "Low Location Accuracy",
                message: "The fix can be sent, but photos may have a less precise location.",
                action: nil,
                actionLabel: nil
            )
        case .missing, .healthy:
            return nil
        }
    }

    static func locationDetail(
        for health: LocationFixHealth,
        permission: LocationPermission,
        timestamp: Date?,
        now: Date
    ) -> String {
        guard permission.allowsForegroundLocation else { return permission.label }
        switch health {
        case .missing:
            return "No fix yet"
        case .invalid:
            return "Invalid fix"
        case .future:
            return "Fix time invalid"
        case .stale:
            return timestamp.map { "Stale · \(relativeUpdate($0, now: now))" } ?? "Stale"
        case .lowAccuracy(let meters, _):
            return "Low accuracy · ±\(Int(meters.rounded())) m"
        case .healthy(let meters, _):
            return "Ready · ±\(Int(meters.rounded())) m"
        }
    }

    static func cameraStatus(_ state: CameraConnectionState) -> String {
        switch state {
        case .idle, .stopped:
            "Not connected"
        case .bluetoothUnavailable:
            "Bluetooth unavailable"
        case .scanning:
            "Searching"
        case .connecting:
            "Connecting"
        case .discovering, .enablingLocation, .pairing:
            "Preparing"
        case .awaitingApproval:
            "Approval required"
        case .unsupported:
            "Unsupported"
        case .linked:
            "Connected"
        case .stopping:
            "Stopping"
        case .failed:
            "Needs attention"
        }
    }

    static func readiness(
        for snapshot: GeotaggingSnapshot,
        health: ConnectionHealth,
        lastUpdate: String,
        now: Date
    ) -> [ReadinessItem] {
        let cameraReady = snapshot.cameraState == .linked
        let cameraDetail =
            cameraReady
            ? "Connected · \(snapshot.cameraName ?? snapshot.targetName)"
            : cameraStatus(snapshot.cameraState)
        let locationReady = health.locationFix.isReady && snapshot.locationPermission.allowsForegroundLocation
        let locationDetail = locationDetail(
            for: health.locationFix,
            permission: snapshot.locationPermission,
            timestamp: snapshot.locationTimestamp,
            now: now
        )
        let sent = snapshot.packetsSent > 0 && snapshot.lastSentAt != nil
        let cameraUpdateReady = sent && health.cameraUpdate.isFresh

        return [
            ReadinessItem(
                id: "camera",
                title: "Camera",
                detail: cameraDetail,
                symbolName: cameraReady ? "camera.fill" : "camera",
                isReady: cameraReady
            ),
            ReadinessItem(
                id: "location",
                title: "iPhone Location",
                detail: locationDetail,
                symbolName: locationReady ? "location.fill" : "location",
                isReady: locationReady
            ),
            ReadinessItem(
                id: "update",
                title: "Last Camera Update",
                detail: sent ? lastUpdate : "Not sent yet",
                symbolName: cameraUpdateReady ? "checkmark.circle.fill" : "clock",
                isReady: cameraUpdateReady
            ),
        ]
    }

}
