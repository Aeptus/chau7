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
    }

    /// Consecutive decrypt failures before ordering a session reset.
    public static let decryptFailureThreshold = 8

    public private(set) var maxReceivedSeq: UInt64 = 0
    private var consecutiveDecryptFailures = 0
    private var currentMacNonce: Data?

    public init() {}

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
            return .resetSession(reason: "mac HELLO nonce changed while session active (agent re-handshake)")
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
            return .resetSession(reason: "\(Self.decryptFailureThreshold) consecutive decrypt failures (stale session key)")
        }
        return .drop(reason: "decrypt failure \(consecutiveDecryptFailures)/\(Self.decryptFailureThreshold)")
    }

    public mutating func noteDecryptSuccess() {
        consecutiveDecryptFailures = 0
    }

    /// Explicit reset (disconnect, pair-accept re-derivation).
    public mutating func reset() {
        resetCounters()
        currentMacNonce = nil
    }

    private mutating func resetCounters() {
        maxReceivedSeq = 0
        consecutiveDecryptFailures = 0
    }
}
