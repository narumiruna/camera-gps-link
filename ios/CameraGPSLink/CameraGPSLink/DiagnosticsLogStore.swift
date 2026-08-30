import Foundation

final class DiagnosticsLogStore: ObservableObject {
    @Published private(set) var lines: [String] = []
    let capacity: Int

    init(capacity: Int = 120) {
        self.capacity = max(1, capacity)
    }

    func append(_ line: String) {
        lines.append(Self.sanitize(line))
        if lines.count > capacity {
            lines.removeFirst(lines.count - capacity)
        }
    }

    func removeAll() {
        lines.removeAll()
    }

    var copyText: String {
        lines.joined(separator: "\n")
    }

    private static func sanitize(_ line: String) -> String {
        let patterns = [
            #"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#,
            #"(?i)\b(?:[0-9a-f]{2}:){5}[0-9a-f]{2}\b"#,
        ]
        var sanitized = line
        for pattern in patterns {
            sanitized = sanitized.replacingOccurrences(
                of: pattern,
                with: "[REDACTED]",
                options: .regularExpression
            )
        }
        if let range = sanitized.range(of: #"(?i)manufacturer(?:_data)?\s*[:=]"#, options: .regularExpression) {
            sanitized = String(sanitized[..<range.upperBound]) + " [REDACTED]"
        }
        if let range = sanitized.range(of: "DD01", options: .caseInsensitive) {
            sanitized = String(sanitized[..<range.upperBound]) + " event payload=[REDACTED]"
        }
        if sanitized.localizedCaseInsensitiveContains("DD11") {
            sanitized = sanitized.replacingOccurrences(
                of: #"[-+]?\d{1,3}\.\d+\s*,\s*[-+]?\d{1,3}\.\d+"#,
                with: "[REDACTED]",
                options: .regularExpression
            )
        }
        return sanitized
    }
}
