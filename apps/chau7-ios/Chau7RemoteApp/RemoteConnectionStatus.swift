import Foundation

/// Connection status for the remote relay session.
///
/// Replaces the previous free-form `String` status so that display text lives in
/// exactly one place and view logic can switch over a closed set of cases
/// instead of matching magic strings (which silently broke on a typo).
enum RemoteConnectionStatus: Equatable {
    case disconnected
    case connecting
    case waitingForMac
    case sessionReady
    case encrypted
    case reconnecting(attempt: Int, max: Int)
    case reconnectingToSendApproval
    case approvalQueued
    case connectionFailed
    case connectionTimedOut
    case pairingRejected
    case error
    case backgroundSuspended

    var displayText: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting"
        case .waitingForMac: return "Waiting for your Mac..."
        case .sessionReady: return "Session ready"
        case .encrypted: return "Encrypted"
        case let .reconnecting(attempt, max): return "Reconnecting (\(attempt)/\(max))..."
        case .reconnectingToSendApproval: return "Reconnecting to send approval..."
        case .approvalQueued: return "Approval queued"
        case .connectionFailed: return "Connection failed"
        case .connectionTimedOut: return "Connection timed out"
        case .pairingRejected: return "Pairing rejected"
        case .error: return "Error"
        case .backgroundSuspended: return "Background suspended"
        }
    }

    /// Whether the encrypted session is fully established, used to drive the
    /// status indicator color.
    var isEncryptedSession: Bool {
        switch self {
        case .encrypted, .sessionReady:
            return true
        default:
            return false
        }
    }
}
