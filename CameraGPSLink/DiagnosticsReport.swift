import Foundation

/// An allowlisted summary, not a redacted rendering of arbitrary BLE or location logs.
enum DiagnosticsReport {
    struct Metadata {
        var appVersion: String?
        var appBuild: String?
        var osVersion: OperatingSystemVersion

        static var current: Metadata {
            Metadata(
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                osVersion: ProcessInfo.processInfo.operatingSystemVersion
            )
        }
    }

    static func make(
        camera: CameraServiceSnapshot,
        mode: SonyDistributionMode,
        metadata: Metadata = .current,
        now: Date = Date()
    ) -> String {
        // Export canonical constants only. A user-assigned name or well-shaped but unknown
        // firmware value is not evidence of a safe identity and must not enter the summary.
        let entry = camera.diagnosticIdentity.flatMap { identity in
            (SonyReleasePolicy.verifiedEntries + SonyReleasePolicy.qualificationEntries)
                .first { $0.matchesIdentity(identity) }
        }
        let version = boundedVersion(metadata.appVersion)
        let build = allowed(metadata.appBuild, pattern: #"\A[0-9]{1,9}\z"#)
        let os = metadata.osVersion
        let osComponents = [os.majorVersion, os.minorVersion, os.patchVersion]
        let osVersion =
            osComponents.allSatisfy { (0...999).contains($0) }
            ? osComponents.map(String.init).joined(separator: ".") : "Unknown"

        return [
            "Camera GPS Link — Diagnostic Summary",
            "App version: \(version)",
            "App build: \(build)",
            "iOS version: \(osVersion)",
            "Distribution: \(distributionLabel(mode))",
            "Camera model: \(entry?.model ?? "Unknown")",
            "Camera firmware: \(entry?.firmware ?? "Unknown")",
            "Camera protocol: \(entry.map { String($0.protocolVersion) } ?? "Unknown")",
            "Connection state: \(camera.state.rawValue)",
            "Last camera update: \(updateAge(camera: camera, now: now))",
            "No coordinates, device identifiers, camera nicknames, or log messages are included.",
        ].joined(separator: "\n")
    }

    private static func boundedVersion(_ value: String?) -> String {
        allowed(value, pattern: #"\A[0-9]{1,3}(?:\.[0-9]{1,3}){0,2}\z"#)
    }

    private static func allowed(_ value: String?, pattern: String) -> String {
        guard let value, value.utf8.count <= 11,
            value.range(of: pattern, options: .regularExpression) != nil
        else { return "Unknown" }
        return value
    }

    private static func distributionLabel(_ mode: SonyDistributionMode) -> String {
        switch mode {
        case .development: "Development"
        case .qualification: "Qualification"
        case .publicRelease: "Public Release"
        }
    }

    private static func updateAge(camera: CameraServiceSnapshot, now: Date) -> String {
        guard camera.packetsSent > 0, let lastSentAt = camera.lastSentAt else { return "Not sent yet" }
        let age = now.timeIntervalSince(lastSentAt)
        guard age.isFinite, (0...315_360_000).contains(age) else { return "Unknown" }
        return "\(Int(age)) seconds ago"
    }
}
