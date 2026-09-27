import Foundation

/// Replay protection with a recovery path.
///
/// The peer (the Go agent) uses a single monotonic sequence counter per
/// crypto session and the WebSocket delivers in order, so a non-increasing
/// seq means a duplicate/replayed frame from a hostile relay — drop it.
///
/// The failure mode this type fixes: when the agent restarts it resets its
/// counter to 1, and a client that kept its high-water mark would then drop
/// *every* subsequent frame as "replayed" forever. The agent's HELLO nonce
/// is effectively the session epoch — a different mac nonce while a crypto
/// session exists means the agent re-handshook, so the guard orders a
/// deliberate session reset instead of a silent deadlock. A run of
/// consecutive decrypt failures triggers the same reset as a safety net
/// (key mismatch looks identical from the client's side).
public struct RemoteReplayGuard: Sendable {

    public enum Action: Equatable, Sendable {
        case accept
        case drop(reason: String)
        /// Tear down crypto/seq state and re-handshake.
        case resetSession(reason: String)
        /// Too many epoch resets inside the window: the peer is not converging,
        /// so in-place re-keying is abandoned in favour of a full transport
        /// restart, which is itself governed by the reconnect backoff.
        ///
        /// A hostile relay can inject an unauthenticated HELLO with an arbitrary
        /// nonce; each one used to order a reset, so a frame at line speed could
        /// keep the session from ever settling.
        case escalate(reason: String)
    }

    /// Consecutive decrypt failures before ordering a session reset.
    public static let decryptFailureThreshold = 8

    /// Epoch resets allowed inside `epochResetWindow` before escalating.
    public static let maxEpochResetsInWindow = 3
    public static let epochResetWindow: TimeInterval = 60

    public private(set) var maxReceivedSeq: UInt64 = 0
    private var consecutiveDecryptFailures = 0
    private var currentMacNonce: Data?
    private var epochResetTimestamps: [Date] = []
    private var lastNow: Date?

    public init() {}

    /// Injectable clock so the window is testable without wall-clock sleeps.
    /// Defaults to the current time.
    public mutating func setNow(_ now: Date) {
        lastNow = now
    }

    private func now() -> Date {
        lastNow ?? Date()
    }

    /// Records an epoch reset and reports whether the caller may act on it.
    /// Returns `.escalate` once the window is exhausted.
    private mutating func admitEpochReset(now: Date) -> Action {
        let cutoff = now.addingTimeInterval(-Self.epochResetWindow)
        epochResetTimestamps.removeAll { $0 < cutoff }
        guard epochResetTimestamps.count < Self.maxEpochResetsInWindow else {
            return .escalate(
                reason: "session epoch reset limit reached (\(Self.maxEpochResetsInWindow) in \(Int(Self.epochResetWindow))s)"
            )
        }
        epochResetTimestamps.append(now)
        return .resetSession(reason: "session epoch reset \(epochResetTimestamps.count)/\(Self.maxEpochResetsInWindow)")
    }

    /// A decrypted frame proves the current epoch is the peer's, so the reset
    /// budget is restored. Without this a long-lived session that legitimately
    /// re-handshook a few times over hours would stay permanently escalated.
    private mutating func clearEpochResetBudget() {
        epochResetTimestamps.removeAll()
    }

    // MARK: - Frame sequencing

    /// Evaluate an encrypted frame's sequence number; accepts bump the
    /// high-water mark.
    public mutating func evaluateEncryptedFrame(seq: UInt64) -> Action {
        guard seq > maxReceivedSeq else {
            return .drop(reason: "replayed/stale frame seq=\(seq) max=\(maxReceivedSeq)")
        }
        maxReceivedSeq = seq
        return .accept
    }

    // MARK: - Session epoch (HELLO nonce)

    /// Evaluate an incoming mac HELLO. A changed nonce while a crypto
    /// session exists means the agent restarted/re-handshook: the old seq
    /// space is dead and must be reset or every future frame drops.
    public mutating func evaluateHello(macNonce: Data, hasCryptoSession: Bool) -> Action {
        defer { currentMacNonce = macNonce }
        if hasCryptoSession, let known = currentMacNonce, known != macNonce {
            resetCounters()
            return admitEpochReset(now: now())
        }
        return .accept
    }

    // MARK: - Decrypt failure safety net

    /// Record a decrypt failure; after `decryptFailureThreshold` consecutive
    /// failures the session key is presumed stale and a reset is ordered.
    public mutating func noteDecryptFailure() -> Action {
        consecutiveDecryptFailures += 1
        if consecutiveDecryptFailures >= Self.decryptFailureThreshold {
            resetCounters()
            return admitEpochReset(now: now())
        }
        return .drop(reason: "decrypt failure \(consecutiveDecryptFailures)/\(Self.decryptFailureThreshold)")
    }

    public mutating func noteDecryptSuccess() {
        consecutiveDecryptFailures = 0
        clearEpochResetBudget()
    }

    /// Explicit reset (disconnect, pair-accept re-derivation).
    public mutating func reset() {
        resetCounters()
        currentMacNonce = nil
        epochResetTimestamps.removeAll()
    }

    private mutating func resetCounters() {
        maxReceivedSeq = 0
        consecutiveDecryptFailures = 0
    }
}
