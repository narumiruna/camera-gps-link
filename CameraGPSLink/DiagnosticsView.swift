import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

struct DiagnosticsView: View {
    @ObservedObject private var appModel: CameraGPSLinkAppModel
    @ObservedObject private var logStore: DiagnosticsLogStore
    @State private var didCopy = false
    @State private var showsPairing = false

    init(appModel: CameraGPSLinkAppModel) {
        _appModel = ObservedObject(wrappedValue: appModel)
        _logStore = ObservedObject(wrappedValue: appModel.diagnosticsStore)
    }

    var body: some View {
        List {
            Section("Camera Connection") {
                diagnosticRow("Target", camera.targetName)
                diagnosticRow("Raw state", camera.state.rawValue)
                if let name = camera.discoveredCameraName {
                    diagnosticRow("Found", name)
                }
                if let firmware = camera.firmware {
                    diagnosticRow("Firmware", firmware)
                } else {
                    diagnosticRow("Firmware", "Unknown")
                }
                diagnosticRow("Protocol", camera.protocolVersion.map(String.init) ?? "Unknown")
                diagnosticRow("Profile", camera.profile?.rawValue.capitalized ?? "Unresolved")
                diagnosticRow("Confidence", camera.confidence.rawValue.capitalized)
                diagnosticRow("Approval", camera.experimentalApprovalPending ? "Required" : "Not pending")
                diagnosticRow("Packets sent", String(camera.packetsSent))
                diagnosticRow("DD11 packet", camera.packetSize.map { "\($0) bytes" } ?? "Not negotiated")
                if let dd21 = camera.dd21ConfigHex {
                    diagnosticRow("DD21 config", dd21, monospaced: true)
                }
                diagnosticRow("DD11 interval", "\(Int(camera.updateInterval)) seconds")
                diagnosticRow("Pending reconnect", camera.pendingReconnectArmed ? "Armed" : "No")
                diagnosticRow("Cleanup", camera.cleanupDiagnostic ?? "Not needed")
                if !camera.operationOrder.isEmpty {
                    diagnosticRow("Operation order", camera.operationOrder.joined(separator: " → "))
                }
                if let sent = camera.lastSentAt {
                    diagnosticRow("Last sent", sent.formatted(date: .abbreviated, time: .standard))
                }
                if let error = camera.lastError {
                    diagnosticError(error)
                }
            }

            Section("Pairing Initialization") {
                diagnosticRow("Status", camera.pairingStatus)
                Text(
                    "EE01 is never part of a location session. "
                        + "Use this only while the camera is explicitly in pairing mode."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                Button("Search and Pair Camera") { showsPairing = true }
                    .accessibilityIdentifier("request-pairing-init")
            }

            Section("Health Alerts") {
                diagnosticRow("Preference", appModel.settings.healthAlertsEnabled ? "On" : "Off")
                diagnosticRow("Notification permission", appModel.notificationAuthorization.label)
                diagnosticRow("Health", appModel.healthMonitorSnapshot.healthClassification)
                diagnosticRow("Managed alerts", appModel.healthMonitorSnapshot.pendingKindLabel)
                diagnosticRow("Next alert", appModel.healthMonitorSnapshot.pendingDeadlineLabel)
            }

            Section("iPhone Location") {
                diagnosticRow("Permission", location.permission.label)
                diagnosticRow("Mode", location.updateModeLabel)
                diagnosticRow("Updating", location.isUpdating ? "Yes" : "No")
                if let current = location.currentLocation {
                    diagnosticRow(
                        "Coordinate",
                        String(format: "%.7f, %.7f", current.coordinate.latitude, current.coordinate.longitude),
                        monospaced: true
                    )
                    diagnosticRow("Accuracy", String(format: "±%.0f m", current.horizontalAccuracy))
                    diagnosticRow("Fix time", current.timestamp.formatted(date: .abbreviated, time: .standard))
                } else {
                    diagnosticRow("Coordinate", "No fix yet")
                    diagnosticRow("Accuracy", "—")
                }
                if let error = location.lastError {
                    diagnosticError(error)
                }
            }

            Section("Debug Log") {
                Text("Diagnostic logs may include recent coordinates. Review them before sharing.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("diagnostics-privacy-warning")

                Button(didCopy ? "Copied Diagnostic Log" : "Copy Diagnostic Log") {
                    copyLog()
                }
                .disabled(logStore.lines.isEmpty)
                .accessibilityIdentifier("copy-diagnostics")

                if logStore.lines.isEmpty {
                    ContentUnavailableView(
                        "No Log Entries",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("Connection activity will appear here.")
                    )
                    .accessibilityIdentifier("diagnostics-empty-log")
                } else {
                    ForEach(Array(logStore.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier("diagnostics-view")
        .sheet(isPresented: $showsPairing) {
            CameraPairingView(appModel: appModel)
        }
    }

    private var camera: CameraServiceSnapshot {
        appModel.cameraSnapshot
    }

    private var location: LocationServiceSnapshot {
        appModel.locationSnapshot
    }

    @ViewBuilder
    private func diagnosticRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                Spacer(minLength: 16)
                valueText(value, monospaced: monospaced)
                    .multilineTextAlignment(.trailing)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                valueText(value, monospaced: monospaced)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(value)")
    }

    private func valueText(_ value: String, monospaced: Bool) -> Text {
        let text = Text(value).foregroundColor(.secondary)
        return monospaced ? text.font(.caption.monospaced()) : text
    }

    private func diagnosticError(_ error: String) -> some View {
        Label(error, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func copyLog() {
        #if canImport(UIKit)
            UIPasteboard.general.string = logStore.copyText
        #endif
        didCopy = true
    }
}
