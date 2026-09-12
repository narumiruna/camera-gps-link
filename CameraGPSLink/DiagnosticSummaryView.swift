import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

struct DiagnosticSummaryView: View {
    let summary: String
    @State private var copiedSummary: String?

    var body: some View {
        Section {
            Text("No coordinates or identifiers.")
                .font(.footnote)
                .foregroundStyle(LinkAppearance.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                copySummary()
            } label: {
                Label(
                    copiedSummary == summary ? "Copied Diagnostic Summary" : "Copy Diagnostic Summary",
                    systemImage: copiedSummary == summary ? "checkmark" : "doc.on.doc"
                )
            }
            .buttonStyle(LinkActionButtonStyle(prominent: false))
            .accessibilityIdentifier("copy-diagnostic-summary")

            DisclosureGroup("Summary Preview") {
                Text(summary)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("diagnostic-summary-preview")
            }
        } header: {
            Label("Diagnostic Summary", systemImage: "doc.text")
        }
        .listRowBackground(LinkAppearance.surface)
    }

    private func copySummary() {
        #if canImport(UIKit)
            UIPasteboard.general.setItems(
                [[UIPasteboard.typeAutomatic: summary]],
                options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(5 * 60)]
            )
            copiedSummary = summary
        #endif
    }
}
