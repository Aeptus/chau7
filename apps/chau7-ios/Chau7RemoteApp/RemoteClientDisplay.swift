import SwiftUI

/// Maps the RemoteClient's typed connection status to user-facing labels and a
/// coarse connection phase used for status colors. Keeping the mapping here means
/// the raw protocol/implementation states (`.encrypted`, `.sessionReady`) never
/// leak into the UI.
extension RemoteClient {
    enum ConnectionPhase {
        case connected
        case connecting
        case warning
        case disconnected

        var color: Color {
            switch self {
            case .connected: return .green
            case .connecting: return .yellow
            case .warning: return .red
            case .disconnected: return .secondary
            }
        }
    }

    var connectionPhase: ConnectionPhase {
        if isConnected {
            switch status {
            case .encrypted, .sessionReady, .approvalQueued:
                return .connected
            default:
                return .connecting
            }
        }
        switch status {
        case .connectionFailed, .connectionTimedOut, .pairingRejected, .error:
            return .warning
        case .disconnected, .backgroundSuspended:
            return .disconnected
        default:
            // .connecting, .waitingForMac, .reconnecting, etc.
            return .connecting
        }
    }

    var connectionDisplayLabel: String {
        if isConnected {
            switch status {
            case .encrypted, .sessionReady:
                return "Connected"
            case .approvalQueued:
                return "Connected · approval queued"
            default:
                return status.displayText
            }
        }
        switch status {
        case .connecting:
            return "Connecting…"
        case .waitingForMac:
            return "Waiting for your Mac…"
        case .reconnecting, .reconnectingToSendApproval:
            return "Reconnecting…"
        case .connectionFailed:
            return "Connection failed"
        case .connectionTimedOut:
            return "Connection timed out"
        case .pairingRejected:
            return "Pairing rejected"
        case .backgroundSuspended:
            return "Paused in background"
        case .disconnected:
            return "Disconnected"
        case .error:
            return "Connection error"
        default:
            return status.displayText
        }
    }
}
