import SwiftUI

/// Maps the RemoteClient's internal status strings to user-facing labels and a
/// coarse connection phase used for status colors. Keeping the mapping here means
/// the raw protocol/implementation states ("Encrypted", "Session ready") never
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
            case "Encrypted", "Session ready", "Approval queued":
                return .connected
            default:
                return .connecting
            }
        }
        switch status {
        case "Connection failed", "Connection timed out", "Pairing rejected", "Error":
            return .warning
        case "Disconnected", "Background suspended":
            return .disconnected
        default:
            // "Connecting", "Waiting for your Mac...", "Reconnecting...", etc.
            return .connecting
        }
    }

    var connectionDisplayLabel: String {
        if isConnected {
            switch status {
            case "Encrypted", "Session ready":
                return "Connected"
            case "Approval queued":
                return "Connected · approval queued"
            default:
                return status
            }
        }
        switch status {
        case "Connecting":
            return "Connecting…"
        case "Waiting for your Mac...":
            return "Waiting for your Mac…"
        case "Reconnecting to send approval...":
            return "Reconnecting…"
        case "Connection failed":
            return "Connection failed"
        case "Connection timed out":
            return "Connection timed out"
        case "Pairing rejected":
            return "Pairing rejected"
        case "Background suspended":
            return "Paused in background"
        case "Disconnected":
            return "Disconnected"
        case "Error":
            return "Connection error"
        default:
            if status.hasPrefix("Reconnecting") {
                return "Reconnecting…"
            }
            return status
        }
    }
}
