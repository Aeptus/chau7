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

    /// Whether the expanded error details should still offer Re-pair as a secondary
    /// route. The inline primary action comes from `RemoteConnectionRecovery`.
    var offersPairingRecovery: Bool {
        switch self {
        case .connectionFailed, .connectionTimedOut, .pairingRejected, .error:
            return true
        default:
            return false
        }
    }

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

/// What the user can do about the current `lastError`.
///
/// The status alone is too coarse to choose a recovery: `.error` covers both a
/// stale pairing and an unrelated input error, and a timeout is usually a
/// transient relay delay rather than a broken pairing. Each failure records its
/// recovery explicitly so the banner can offer the action that actually helps.
enum RemoteConnectionRecovery: Equatable {
    /// The pairing itself is unusable (stale credential, changed Mac identity,
    /// rejected pairing, malformed relay URL). Only a fresh QR scan fixes it.
    case repairRequired
    /// A transient network or relay failure. Retrying the same pairing may work.
    case retryable
    /// Informational or input-level errors with no connection recovery.
    case none
}

/// A connection failure with its user-facing explanation and recovery.
///
/// RemoteClient reports failures through these constructors so the message and
/// the recovery choice cannot drift apart.
struct RemoteConnectionFailure: Equatable {
    let message: String
    let recovery: RemoteConnectionRecovery

    /// Legacy pairing without a provisioned relay credential.
    static let staleRelayCredential = RemoteConnectionFailure(
        message: "This pairing needs a provisioned relay credential. Scan a fresh QR code from your Mac.",
        recovery: .repairRequired
    )

    /// PAIR_ACCEPT carried a Mac key that does not match the stored pairing.
    static let macIdentityChanged = RemoteConnectionFailure(
        message: "The Mac identity changed. Scan a fresh pairing code before reconnecting.",
        recovery: .repairRequired
    )

    static let insecureRelayURL = RemoteConnectionFailure(
        message: "Relay URL must use wss:// (encrypted transport). Scan a fresh QR code from your Mac.",
        recovery: .repairRequired
    )

    static let invalidRelayURL = RemoteConnectionFailure(
        message: "Invalid relay URL. Scan a fresh QR code from your Mac.",
        recovery: .repairRequired
    )

    /// The Mac did not answer the handshake in time.
    static let handshakeTimedOut = RemoteConnectionFailure(
        message: "No response from your Mac. Make sure Chau7 is open, Remote is enabled, and the pairing payload is still current.",
        recovery: .retryable
    )

    static func pairingRejected(reason: String?) -> RemoteConnectionFailure {
        let message: String
        if let reason, !reason.isEmpty {
            message = "Pairing rejected: \(reason). Scan a fresh QR code from your Mac."
        } else {
            message = "Pairing rejected. Scan a fresh QR code from your Mac."
        }
        return RemoteConnectionFailure(message: message, recovery: .repairRequired)
    }

    /// The reconnect budget ran out, typically because the relay or Mac is unreachable.
    static func reconnectLimitReached(attempts: Int) -> RemoteConnectionFailure {
        RemoteConnectionFailure(
            message: "Could not reach your Mac after \(attempts) attempts. Check your network and that Chau7 is open on your Mac, then retry.",
            recovery: .retryable
        )
    }
}

/// The primary action shown inline next to the collapsed error banner.
enum RemoteErrorBannerAction: Hashable {
    case repair
    case retry
    case none

    static func primary(for recovery: RemoteConnectionRecovery, isConnected: Bool) -> RemoteErrorBannerAction {
        switch recovery {
        case .repairRequired:
            return .repair
        case .retryable:
            return isConnected ? .none : .retry
        case .none:
            return .none
        }
    }

    /// Actions shown in the expanded details, after the primary one.
    ///
    /// A broken pairing gets no Retry (it would fail the same way). A transient
    /// failure keeps Re-pair reachable because the pairing may also be outdated.
    /// Unclassified errors fall back to the status-based offer.
    static func secondary(
        for recovery: RemoteConnectionRecovery,
        isConnected: Bool,
        status: RemoteConnectionStatus
    ) -> [RemoteErrorBannerAction] {
        switch recovery {
        case .repairRequired:
            return []
        case .retryable:
            return [.repair]
        case .none:
            var actions: [RemoteErrorBannerAction] = []
            if !isConnected { actions.append(.retry) }
            if status.offersPairingRecovery { actions.append(.repair) }
            return actions
        }
    }
}
