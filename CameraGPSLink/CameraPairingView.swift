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
                    Text(pairing.bluetooth.guidance)
                    Text(
                        "Keep the camera nearby. Accept Bluetooth pairing requests on both the iPhone and camera. Location permission is not needed to pair."
                    )
                    if pairing.bluetooth == .denied || pairing.bluetooth == .poweredOff {
                        Button("Open iPhone Settings", action: appModel.openSettings)
                            .accessibilityIdentifier("pairing-settings")
                    }
                }

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
                    Button("Search for Cameras", action: appModel.requestPairingInitialization)
                        .disabled(!pairing.canSearch)
                        .accessibilityIdentifier("search-pairing-cameras")
                    if !pairing.canSearch && !pairing.isPairing {
                        Text("Stop geotagging before adding a camera.")
                    }
                }

                if !pairing.cameras.isEmpty {
                    Section("Select Your Camera") {
                        ForEach(pairing.cameras) { candidate in
                            Button {
                                appModel.selectPairingCamera(id: candidate.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(candidate.name)
                                    Text("Signal: \(candidate.rssi) dBm")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
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
                }
                if pairing.isPairing && camera.pairingConfirmationPending {
                    Section("Confirm on the Camera") {
                        Text(
                            "Is the camera on its Bluetooth pairing screen? This sends Sony pairing initialization once. It does not start location sharing."
                        )
                        Button("Pair with This Camera", action: appModel.confirmPairingInitialization)
                            .accessibilityIdentifier("confirm-camera-pairing")
                    }
                }
                if pairing.isPairing && camera.state == .failed {
                    Section("If Pairing Still Fails") {
                        Text(
                            "If pairing information is inconsistent, forget this camera in iPhone Settings → Bluetooth and remove this iPhone in the camera's Manage Paired Device menu. Open the camera pairing screen and search again."
                        )
                    }
                }
            }
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
        .onDisappear { appModel.cancelPairingInitialization() }
    }
}
