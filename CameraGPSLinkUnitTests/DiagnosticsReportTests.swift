import XCTest

@testable import CameraGPSLink

final class DiagnosticsReportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)
    private let metadata = DiagnosticsReport.Metadata(
        appVersion: "0.1", appBuild: "42",
        osVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 5, patchVersion: 0)
    )

    func testSummaryContainsOnlyDeterministicAllowlistedFields() {
        let report = DiagnosticsReport.make(camera: camera(), mode: .qualification, metadata: metadata, now: now)
        XCTAssertEqual(
            report,
            """
            Camera GPS Link — Diagnostic Summary
            App version: 0.1
            App build: 42
            iOS version: 26.5.0
            Distribution: Qualification
            Camera model: ILCE-7CM2
            Camera firmware: 2.01
            Camera protocol: 101
            Connection state: linked
            Last camera update: 12 seconds ago
            No coordinates, device identifiers, camera nicknames, or log messages are included.
            """)
    }

    func testUnknownIdentityDoesNotExportRawOrPartiallyMatchingValues() {
        let identities: [SonyCameraIdentity?] = [
            nil,
            SonyCameraIdentity(model: "ILCE-7CM2", firmware: "9.99", protocolVersion: 101),
            SonyCameraIdentity(model: "ILCE-7CM2", firmware: "2.01", protocolVersion: nil),
            SonyCameraIdentity(model: "ILCE-7CM2", firmware: "2.01", protocolVersion: 102),
            SonyCameraIdentity(model: "Personal camera", firmware: "2.01", protocolVersion: 101),
        ]
        for identity in identities {
            var snapshot = camera()
            snapshot.diagnosticIdentity = identity
            let report = DiagnosticsReport.make(camera: snapshot, mode: .publicRelease, metadata: metadata, now: now)
            XCTAssertTrue(report.contains("Camera model: Unknown\nCamera firmware: Unknown\nCamera protocol: Unknown"))
            XCTAssertTrue(report.contains("Distribution: Public Release"))
        }
    }

    func testAdversarialIdentityAndFreeFormFieldsCannotEnterSummary() {
        let sensitiveValues = [
            "35.6812360, 139.7671250",
            "camera at 35.6812360/139.7671250",
            "8A99290C-4FF4-4ED2-9D9B-9E6F8CD82928",
            "AA:BB:CC:DD:EE:FF",
            "manufacturer_data=001122aabbcc",
            "DD11 payload=5f00112233445566778899",
            "DD01 event payload=11223344",
            "ILCE-7CM2\nCoordinate: 35.681236,139.767125",
            "ILCE-7CM2\u{0}hidden",
            "https://example.invalid/?coordinate=35.681236,139.767125",
            String(repeating: "private", count: 1_000),
        ]
        for value in sensitiveValues {
            var snapshot = camera()
            snapshot.discoveredCameraName = value
            snapshot.targetName = value
            snapshot.firmware = value
            snapshot.protocolVersion = Int.max
            snapshot.dd21ConfigHex = value
            snapshot.pairingStatus = value
            snapshot.cleanupDiagnostic = value
            snapshot.operationOrder = [value]
            snapshot.lastError = value
            snapshot.diagnosticIdentity = SonyCameraIdentity(model: value, firmware: value, protocolVersion: 101)
            let report = DiagnosticsReport.make(camera: snapshot, mode: .development, metadata: metadata, now: now)
            XCTAssertFalse(report.contains(value))
            XCTAssertTrue(report.contains("Camera model: Unknown"))
            XCTAssertTrue(report.contains("Distribution: Development"))
            XCTAssertLessThan(report.count, 600)
        }
    }

    func testFirmwareCannotLeakEvenWhenModelMatches() {
        for firmware in ["35.681236", "2.01\nprivate", "AA:BB:CC:DD:EE:FF"] {
            var snapshot = camera()
            snapshot.diagnosticIdentity = SonyCameraIdentity(
                model: "ILCE-7CM2", firmware: firmware, protocolVersion: 101)
            let report = DiagnosticsReport.make(camera: snapshot, mode: .qualification, metadata: metadata, now: now)
            XCTAssertFalse(report.contains(firmware))
            XCTAssertTrue(report.contains("Camera firmware: Unknown"))
        }
    }

    func testNoConfirmedPacketAndMalformedTimesRemainSafe() {
        var snapshot = camera()
        snapshot.packetsSent = 0
        XCTAssertTrue(summary(snapshot).contains("Last camera update: Not sent yet"))
        snapshot.packetsSent = 1
        snapshot.lastSentAt = nil
        XCTAssertTrue(summary(snapshot).contains("Last camera update: Not sent yet"))
        for interval in [Double.nan, .infinity, -.infinity, 10_001, -Double.greatestFiniteMagnitude] {
            snapshot.lastSentAt = Date(timeIntervalSince1970: interval)
            XCTAssertTrue(summary(snapshot).contains("Last camera update: Unknown"))
        }
        snapshot.lastSentAt = now
        XCTAssertTrue(summary(snapshot).contains("Last camera update: 0 seconds ago"))
    }

    func testMalformedMetadataCannotAddArbitraryText() {
        for value in [nil, "", "0.1\nPrivate", "35.681236", "1.2.3.4", "AA:BB:CC:DD:EE:FF", "1\n"] as [String?] {
            let metadata = DiagnosticsReport.Metadata(
                appVersion: value, appBuild: value,
                osVersion: OperatingSystemVersion(majorVersion: -1, minorVersion: Int.max, patchVersion: 0)
            )
            let report = DiagnosticsReport.make(camera: camera(), mode: .development, metadata: metadata, now: now)
            XCTAssertTrue(report.contains("App version: Unknown\nApp build: Unknown\niOS version: Unknown"))
        }
    }

    private func summary(_ snapshot: CameraServiceSnapshot) -> String {
        DiagnosticsReport.make(camera: snapshot, mode: .development, metadata: metadata, now: now)
    }

    private func camera() -> CameraServiceSnapshot {
        CameraServiceSnapshot(
            state: .linked, discoveredCameraName: "Personal nickname", targetName: "Raw advertisement",
            packetsSent: 1, lastSentAt: now.addingTimeInterval(-12), includeTimezone: true,
            dd21ConfigHex: "06 10 00 9c 02 00 00", firmware: "untrusted", protocolVersion: 999,
            profile: .modern, confidence: .experimental, packetSize: 95,
            experimentalApprovalPending: false, pairingConfirmationPending: false,
            pairingStatus: "Not requested", cleanupDiagnostic: nil, operationOrder: [], lastError: nil,
            pendingReconnectArmed: false, activeLinkIntent: true, updateInterval: 120,
            diagnosticIdentity: SonyCameraIdentity(model: "ILCE-7CM2", firmware: "2.01", protocolVersion: 101)
        )
    }
}
