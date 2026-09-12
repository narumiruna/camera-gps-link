import SwiftUI

struct LinkSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let current: LinkSettings
    let allowsBackground: Bool
    let notificationAuthorization: HealthNotificationAuthorization
    let requestNotificationAuthorization: () -> Void
    let openSystemSettings: () -> Void
    let apply: (LinkSettings) -> Bool

    @State private var draft: LinkSettingsDraft
    @State private var applyError: String?
    @State private var isApplying = false

    init(
        current: LinkSettings,
        allowsBackground: Bool,
        notificationAuthorization: HealthNotificationAuthorization,
        requestNotificationAuthorization: @escaping () -> Void,
        openSystemSettings: @escaping () -> Void,
        apply: @escaping (LinkSettings) -> Bool
    ) {
        self.current = current
        self.allowsBackground = allowsBackground
        self.notificationAuthorization = notificationAuthorization
        self.requestNotificationAuthorization = requestNotificationAuthorization
        self.openSystemSettings = openSystemSettings
        self.apply = apply
        _draft = State(initialValue: LinkSettingsDraft(current: current))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Connection Availability", selection: $draft.value.connectionAvailability) {
                        ForEach(ConnectionAvailability.availableOptions(allowsBackground: allowsBackground)) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                    .accessibilityIdentifier("connection-availability")
                    .focusable()
                } header: {
                    Label("Connection Availability", systemImage: "antenna.radiowaves.left.and.right")
                }
                .listRowBackground(LinkAppearance.surface)

                Section {
                    Picker("Location Updates", selection: $draft.value.locationUpdates) {
                        ForEach(LocationUpdateMode.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                    .accessibilityIdentifier("location-updates")
                    .focusable()
                } header: {
                    Label("Location Updates", systemImage: "location")
                }
                .listRowBackground(LinkAppearance.surface)

                Section {
                    Toggle(isOn: $draft.value.healthAlertsEnabled) {
                        Label("Health Alerts", systemImage: "bell.badge")
                    }
                    .accessibilityIdentifier("health-alerts-toggle")
                    LabeledContent("Notification Permission", value: notificationAuthorization.label)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("health-alerts-permission")
                    if draft.value.healthAlertsEnabled,
                        current.healthAlertsEnabled,
                        notificationAuthorization == .notDetermined
                    {
                        Button("Retry Notification Permission", action: requestNotificationAuthorization)
                            .accessibilityIdentifier("health-alerts-retry-permission")
                    }
                    if draft.value.healthAlertsEnabled, notificationAuthorization == .denied {
                        Button("Open iOS Settings", action: openSystemSettings)
                            .accessibilityIdentifier("health-alerts-open-settings")
                    }
                } header: {
                    Label("Health Alerts", systemImage: "heart.text.square")
                } footer: {
                    Text(
                        "Warns about interrupted or outdated camera location updates. "
                            + "Notifications do not keep the app running."
                    )
                }
                .listRowBackground(LinkAppearance.surface)

                Section("Effect Preview") {
                    HStack(alignment: .top, spacing: 12) {
                        LinkIcon(symbol: "sparkles")
                        VStack(alignment: .leading, spacing: 8) {
                            Text(draft.value.summary)
                                .font(.headline)
                            Text(draft.value.effectPreview)
                                .font(.subheadline)
                                .foregroundStyle(LinkAppearance.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Effect preview. \(draft.value.summary). \(draft.value.effectPreview)")
                    .accessibilityIdentifier("settings-preview")
                }
                .listRowBackground(LinkAppearance.accentSurface)

                if let applyError {
                    Section {
                        Label(applyError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("settings-error")
                    }
                    .listRowBackground(LinkAppearance.surface)
                }
            }
            .linkListBackground()
            .navigationTitle("Link Settings")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .interactiveDismissDisabled(isApplying)
            .onKeyPress(.escape) {
                guard !isApplying else { return .ignored }
                cancelDraft()
                return .handled
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        cancelDraft()
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isApplying)
                    .accessibilityIdentifier("settings-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        applyDraft()
                    }
                    .fontWeight(.semibold)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.hasChanges || isApplying)
                    .accessibilityIdentifier("settings-apply")
                }
            }
        }
        .tint(LinkAppearance.accent)
    }

    private func cancelDraft() {
        draft.cancel()
        dismiss()
    }

    private func applyDraft() {
        isApplying = true
        applyError = nil
        if apply(draft.value) {
            dismiss()
        } else {
            applyError = "Changes couldn’t be applied. Your previous settings are still active."
            isApplying = false
        }
    }
}
