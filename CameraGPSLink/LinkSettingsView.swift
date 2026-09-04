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
                    Text("Connection Availability")
                }

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
                    Text("Location Updates")
                }

                Section {
                    Toggle("Health Alerts", isOn: $draft.value.healthAlertsEnabled)
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
                    Text("Health Alerts")
                } footer: {
                    Text(
                        "Warns about interrupted or outdated camera location updates. "
                            + "Notifications do not keep the app running."
                    )
                }

                Section("Effect Preview") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(draft.value.summary)
                            .font(.headline)
                        Text(draft.value.effectPreview)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Effect preview. \(draft.value.summary). \(draft.value.effectPreview)")
                    .accessibilityIdentifier("settings-preview")
                }

                if let applyError {
                    Section {
                        Label(applyError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("settings-error")
                    }
                }
            }
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
                    .focusable()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        applyDraft()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.hasChanges || isApplying)
                    .accessibilityIdentifier("settings-apply")
                    .focusable()
                }
            }
        }
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
