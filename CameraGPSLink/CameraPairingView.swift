import SwiftUI

struct CameraPairingView: View {
    @ObservedObject var appModel: CameraGPSLinkAppModel
    @Environment(\.dismiss) private var dismiss

    private var camera: CameraServiceSnapshot { appModel.cameraSnapshot }
    private var pairing: CameraPairingSnapshot { camera.pairing }

    var body: some View {
        NavigationStack {
            List {
                Section("Before You Start") {
                    HStack(alignment: .top, spacing: 12) {
                        LinkIcon(symbol: "camera.badge.ellipsis")
                        VStack(alignment: .leading, spacing: 8) {
                            Text(pairing.bluetooth.guidance)
                                .font(.headline)
                            Text(
                                "Keep the camera nearby. Accept Bluetooth pairing requests on both the iPhone and camera. Location permission is not needed to pair."
                            )
                            .font(.subheadline)
                            .foregroundStyle(LinkAppearance.secondaryText)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 8)
                    if pairing.bluetooth == .denied || pairing.bluetooth == .poweredOff {
                        Button("Open iPhone Settings", action: appModel.openSettings)
                            .accessibilityIdentifier("pairing-settings")
                    }
                }
                .listRowBackground(LinkAppearance.surface)

                Section("Camera Pairing") {
                    if pairing.isPairing {
                        Text(camera.pairingStatus)
                            .accessibilityIdentifier("pairing-status")
                        if let error = camera.lastError {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                        }
                    }
                    if pairing.completed {
                        Label("Pairing Initialization Accepted", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                            .foregroundStyle(LinkAppearance.positive)
                            .accessibilityIdentifier("pairing-complete")
                        Text(
                            "This is the camera's write acknowledgement, not an independent check of the iOS bond. Close this screen and start geotagging to verify the location link."
                        )
                    } else if pairing.waitingForBluetooth
                        || (pairing.isPairing
                            && [.scanning, .connecting, .discovering].contains(camera.state))
                        || (pairing.isPairing && camera.state == .pairing && !camera.pairingConfirmationPending)
                    {
                        ProgressView(
                            "\(pairing.waitingForBluetooth ? "Waiting for Bluetooth" : "Working with camera")…")
                    }
                    Button(action: appModel.requestPairingInitialization) {
                        Label("Search for Cameras", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(LinkActionButtonStyle())
                    .listRowSeparator(.hidden)
                    .disabled(!pairing.canSearch)
                    .accessibilityIdentifier("search-pairing-cameras")
                    if !pairing.canSearch && !pairing.isPairing {
                        Text("Stop geotagging before adding a camera.")
                    }
                }
                .listRowBackground(LinkAppearance.surface)

                if !pairing.cameras.isEmpty {
                    Section("Select Your Camera") {
                        ForEach(pairing.cameras) { candidate in
                            Button {
                                appModel.selectPairingCamera(id: candidate.id)
                            } label: {
                                HStack(spacing: 12) {
                                    LinkIcon(symbol: "camera.fill")
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(candidate.name)
                                            .font(.headline)
                                            .foregroundStyle(.primary)
                                        Label(
                                            "Signal: \(candidate.rssi) dBm",
                                            systemImage: "antenna.radiowaves.left.and.right"
                                        )
                                        .font(.caption)
                                        .foregroundStyle(LinkAppearance.secondaryText)
                                    }
                                    .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 4)
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .accessibilityHidden(true)
                                }
                                .padding(.vertical, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(LinkAppearance.surface)
                            .accessibilityIdentifier("pairing-camera")
                        }
                    }
                }

                if pairing.isPairing && camera.experimentalApprovalPending {
                    Section("Experimental Camera") {
                        Text(
                            "\(camera.discoveredCameraName ?? camera.targetName) has not been verified for this build. Continue only if you want to allow its pairing initialization."
                        )
                        Button("Approve Experimental Pairing", action: appModel.approveExperimentalProfile)
                            .accessibilityIdentifier("approve-pairing-profile")
                    }
                    .listRowBackground(LinkAppearance.warningSurface)
                }
                if pairing.isPairing && camera.pairingConfirmationPending {
                    Section("Confirm on the Camera") {
                        Text(
                            "Is the camera on its Bluetooth pairing screen? This sends Sony pairing initialization once. It does not start location sharing."
                        )
                        Button(action: appModel.confirmPairingInitialization) {
                            Label("Pair with This Camera", systemImage: "link")
                        }
                        .buttonStyle(LinkActionButtonStyle())
                        .accessibilityIdentifier("confirm-camera-pairing")
                    }
                    .listRowBackground(LinkAppearance.surface)
                }
                if pairing.isPairing && camera.state == .failed {
                    Section("If Pairing Still Fails") {
                        Text(
                            "If pairing information is inconsistent, forget this camera in iPhone Settings → Bluetooth and remove this iPhone in the camera's Manage Paired Device menu. Open the camera pairing screen and search again."
                        )
                    }
                    .listRowBackground(LinkAppearance.warningSurface)
                }
            }
            .linkListBackground()
            .navigationTitle("Add Camera")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(pairing.completed ? "Done" : "Cancel") {
                        appModel.cancelPairingInitialization()
                        dismiss()
                    }
                    .accessibilityIdentifier("close-camera-pairing")
                }
            }
        }
        .tint(LinkAppearance.accent)
        .onDisappear { appModel.cancelPairingInitialization() }
    }
}
