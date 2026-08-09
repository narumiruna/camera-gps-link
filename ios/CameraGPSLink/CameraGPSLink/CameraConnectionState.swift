import Foundation

enum CameraConnectionState: String {
    case idle
    case bluetoothUnavailable
    case scanning
    case connecting
    case discovering
    case awaitingApproval
    case enablingLocation
    case linked
    case pairing
    case unsupported
    case stopping
    case stopped
    case failed

    var label: String {
        switch self {
        case .idle:
            "Idle"
        case .bluetoothUnavailable:
            "Bluetooth unavailable"
        case .scanning:
            "Scanning"
        case .connecting:
            "Connecting"
        case .discovering:
            "Discovering services"
        case .awaitingApproval:
            "Approval required"
        case .enablingLocation:
            "Enabling location link"
        case .linked:
            "Location link active"
        case .pairing:
            "Pairing initialization"
        case .unsupported:
            "Unsupported camera profile"
        case .stopping:
            "Stopping"
        case .stopped:
            "Stopped"
        case .failed:
            "Failed"
        }
    }
}
