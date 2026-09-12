import SwiftUI

struct GeotaggingHomeView<Diagnostics: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let state: GeotaggingViewState
    let settings: LinkSettings
    let perform: (GeotaggingAction) -> Void
    let showSettings: () -> Void
    @ViewBuilder let diagnostics: () -> Diagnostics

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                statusSection
                readinessSection
                toolsSection
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .background(LinkAppearance.page)
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                statusEmblem
                VStack(alignment: .leading, spacing: 5) {
                    if !dynamicTypeSize.isAccessibilitySize {
                        Text("LOCATION LINK")
                            .font(.caption2.weight(.bold))
                            .tracking(1.6)
                            .foregroundStyle(LinkAppearance.secondaryText)
                    }
                    Text(state.title)
                        .font(.title2.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }
            }

            Text(state.message)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)

            if state.showsProgress {
                ProgressView()
                    .tint(LinkAppearance.accent)
                    .accessibilityLabel(state.title)
                    .accessibilityIdentifier("connection-progress")
            }

            ForEach(state.notices) { notice in
                noticeCard(notice)
            }

            VStack(spacing: 10) {
                actionButtons
            }

            if let explanation = state.foregroundOnlyMessage {
                Label(explanation, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(LinkAppearance.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("foreground-only-explanation")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .linkCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("geotagging-status")
    }

    private var statusEmblem: some View {
        Image(systemName: statusSymbol)
            .font(.system(size: 25, weight: .medium))
            .foregroundStyle(statusColor)
            .frame(width: 56, height: 56)
            .background(statusColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
            .accessibilityHidden(true)
    }

    private func noticeCard(_ notice: StatusNotice) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(notice.title, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LinkAppearance.warning)
                .fixedSize(horizontal: false, vertical: true)
            Text(notice.message)
                .font(.footnote)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let action = notice.action, let actionLabel = notice.actionLabel {
                Button(actionLabel) {
                    perform(action)
                }
                .buttonStyle(LinkActionButtonStyle(prominent: false))
                .accessibilityIdentifier("notice-action-\(notice.id)")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinkAppearance.warningSurface, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notice-\(notice.id)")
    }

    @ViewBuilder
    private var actionButtons: some View {
        if let action = state.primaryAction, let label = state.primaryActionLabel {
            Button {
                perform(action)
            } label: {
                Label(label, systemImage: actionSymbol(action))
            }
            .buttonStyle(LinkActionButtonStyle())
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("primary-action")
            .focusable()
        }

        if let action = state.secondaryAction, let label = state.secondaryActionLabel {
            Button {
                perform(action)
            } label: {
                Label(label, systemImage: actionSymbol(action))
            }
            .buttonStyle(LinkActionButtonStyle(prominent: false))
            .accessibilityIdentifier("secondary-action")
            .focusable()
        }
    }

    private var readinessSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Readiness")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 4)

            ForEach(Array(state.readiness.enumerated()), id: \.element.id) { index, item in
                readinessRow(item)
                if index < state.readiness.count - 1 {
                    Divider().overlay(LinkAppearance.secondaryText.opacity(0.08))
                        .padding(.leading, 50)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 4)
        .linkCard()
        .accessibilityIdentifier("readiness")
    }

    private func readinessRow(_ item: ReadinessItem) -> some View {
        HStack(alignment: .center, spacing: 12) {
            LinkIcon(
                symbol: item.symbolName,
                color: item.isReady ? LinkAppearance.positive : LinkAppearance.secondaryText
            )
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.title)
                        .font(.subheadline.weight(.medium))
                    Spacer(minLength: 12)
                    Text(item.detail)
                        .font(.subheadline)
                        .foregroundStyle(LinkAppearance.secondaryText)
                        .multilineTextAlignment(.trailing)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.subheadline.weight(.medium))
                    Text(item.detail)
                        .font(.subheadline)
                        .foregroundStyle(LinkAppearance.secondaryText)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title), \(item.detail)")
        .accessibilityIdentifier("readiness-\(item.id)")
    }

    private var toolsSection: some View {
        VStack(spacing: 0) {
            Button(action: showSettings) {
                toolRow(title: "Link Settings", detail: settings.summary, symbol: "slider.horizontal.3")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Link Settings, \(settings.summary)")
            .accessibilityHint("Opens settings with a preview before applying changes")
            .accessibilityIdentifier("link-settings")
            .focusable()

            Divider().padding(.leading, 68)

            NavigationLink(destination: diagnostics) {
                toolRow(
                    title: "Diagnostics",
                    detail: "Connection details and debug log",
                    symbol: "waveform.path.ecg"
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("diagnostics-link")
            .focusable()
        }
        .linkCard()
    }

    private func toolRow(title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            LinkIcon(symbol: symbol)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(LinkAppearance.secondaryText)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(LinkAppearance.secondaryText)
                .accessibilityHidden(true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func actionSymbol(_ action: GeotaggingAction) -> String {
        switch action {
        case .start: "location.fill"
        case .cancel: "xmark"
        case .approveExperimental: "checkmark.shield"
        case .retry: "arrow.clockwise"
        case .stop: "stop.fill"
        case .sendNow: "location.north.line.fill"
        case .openSettings: "gearshape"
        case .requestBackgroundPermission: "location"
        }
    }

    private var statusSymbol: String {
        switch state.phase {
        case .ready:
            "checkmark.circle.fill"
        case .needsAttention, .approvalRequired, .unsupported, .usingCachedLocation:
            "exclamationmark.triangle.fill"
        case .searching, .connecting, .preparing, .sendingFirstLocation, .requestingPermission, .stopping:
            "arrow.triangle.2.circlepath"
        case .waitingInBackground, .waitingForLocation:
            "clock.fill"
        case .notConnected, .stopped:
            "camera"
        }
    }

    private var statusColor: Color {
        switch state.phase {
        case .ready:
            LinkAppearance.positive
        case .needsAttention, .approvalRequired, .unsupported, .usingCachedLocation:
            LinkAppearance.warning
        default:
            LinkAppearance.accent
        }
    }
}
