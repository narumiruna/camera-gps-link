import CoreBluetooth
import Foundation

struct PairingCamera: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int
    let protocolVersion: Int?

    static func discovered(
        id: UUID, name: String?, manufacturerData: Data?, rssi: Int, isConnectable: Bool
    ) -> PairingCamera? {
        guard isConnectable,
            let manufacturerData, manufacturerData.count >= 4,
            manufacturerData.prefix(2) == Data([0x2D, 0x01]),
            let advertisement = SonyProtocol.parseAdvertisement(manufacturerData: manufacturerData),
            advertisement.isCamera
        else { return nil }
        return PairingCamera(
            id: id,
            name: name.flatMap { $0.isEmpty ? nil : $0 } ?? "Sony camera",
            rssi: rssi,
            protocolVersion: advertisement.protocolVersion
        )
    }
}

enum CameraBluetoothAvailability: Equatable {
    case starting, ready, poweredOff, denied, unsupported

    init(_ state: CBManagerState) {
        switch state {
        case .poweredOn: self = .ready
        case .poweredOff: self = .poweredOff
        case .unauthorized: self = .denied
        case .unsupported: self = .unsupported
        case .unknown, .resetting: self = .starting
        @unknown default: self = .unsupported
        }
    }

    var guidance: String {
        switch self {
        case .starting:
            "Allow Bluetooth access when iOS asks. Keep this app open while Bluetooth starts."
        case .ready:
            "On the camera, enable Bluetooth and open Bluetooth → Pairing or Smartphone Connection."
        case .poweredOff:
            "Turn on Bluetooth in iPhone Settings. This app cannot turn it on for you."
        case .denied:
            "Allow Bluetooth for Camera GPS Link in iPhone Settings, then search again."
        case .unsupported:
            "Bluetooth is unavailable on this device. Use a Bluetooth-capable iPhone."
        }
    }
}

struct CameraPairingSnapshot: Equatable {
    var bluetooth: CameraBluetoothAvailability = .starting
    var cameras: [PairingCamera] = []
    var canSearch = true
    var isPairing = false
    var waitingForBluetooth = false
    var completed = false
}
