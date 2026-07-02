import CryptoKit
import Foundation
import Chau7Core
import os

private let log = Logger(subsystem: "ch7", category: "RemoteSession")

/// Owns the E2E crypto-session state machine: key material (device key, Mac
/// public key, handshake nonces), the outbound sequence counter, the derived
/// `RemoteCryptoSession`, and the replay guard.
///
/// Extracted from `RemoteClient` (C6): establishment here is side-effect
/// free — `establishIfPossible()` returns an outcome and the client owns the
/// consequences (status, telemetry, flushes). All state transitions that
/// used to be scattered inline (`crypto = nil; seqCounter = 1;
/// maxReceivedSeq = 0; nonce…`) go through named methods, so the teardown
/// rules live in exactly one place.
@MainActor
final class RemoteSessionController {

    enum EstablishOutcome: Equatable {
        /// A session already exists or handshake material is still missing —
        /// nothing to do.
        case notReady
        /// Key agreement or session derivation failed (user-facing message).
        case failed(String)
        /// A fresh crypto session was derived.
        case established
    }

    /// This device's long-lived key pair (Keychain-backed).
    let iosKey: Curve25519.KeyAgreement.PrivateKey

    private(set) var crypto: RemoteCryptoSession?
    private(set) var nonceIOS: Data?
    private(set) var nonceMac: Data?
    private(set) var macPublicKey: Curve25519.KeyAgreement.PublicKey?
    private(set) var hasReceivedPairAccept = false

    private var seqCounter: UInt64 = 1
    private var replayGuard = RemoteReplayGuard()

    init(iosKey: Curve25519.KeyAgreement.PrivateKey) {
        self.iosKey = iosKey
    }

    var isEstablished: Bool {
        crypto != nil
    }

    /// SHA-256 fingerprint of this device's public key, for out-of-band
    /// verification against the value shown by the Mac.
    var iosKeyFingerprint: String {
        CryptoUtils.fingerprint(data: iosKey.publicKey.rawRepresentation)
    }

    // MARK: - Handshake material

    func adoptMacPublicKey(_ keyData: Data) -> Bool {
        do {
            macPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: keyData)
            return true
        } catch {
            log.error("Invalid Mac public key: \(error.localizedDescription)")
            return false
        }
    }

    func setMacNonce(_ nonce: Data) {
        nonceMac = nonce
    }

    /// Forget the Mac's nonce so establishment waits for its fresh HELLO
    /// (explicit re-pairing: both sides re-handshake with new nonces).
    func clearMacNonce() {
        nonceMac = nil
    }

    /// Mint a fresh iOS nonce (start of a handshake attempt).
    @discardableResult
    func mintIOSNonce() -> Data {
        let nonce = CryptoUtils.randomBytes(count: 16)
        nonceIOS = nonce
        return nonce
    }

    func markPairAcceptReceived() {
        hasReceivedPairAccept = true
    }

    // MARK: - Sequencing / replay protection

    func nextSeq() -> UInt64 {
        defer { seqCounter &+= 1 }
        return seqCounter
    }

    func evaluateEncryptedFrame(seq: UInt64) -> RemoteReplayGuard.Action {
        replayGuard.evaluateEncryptedFrame(seq: seq)
    }

    func evaluateHello(macNonce: Data) -> RemoteReplayGuard.Action {
        replayGuard.evaluateHello(macNonce: macNonce, hasCryptoSession: crypto != nil)
    }

    func noteDecryptFailure() -> RemoteReplayGuard.Action {
        replayGuard.noteDecryptFailure()
    }

    func noteDecryptSuccess() {
        replayGuard.noteDecryptSuccess()
    }

    // MARK: - Establishment / teardown

    /// Derive the crypto session when both nonces and the Mac key are known.
    /// Side-effect free beyond this controller's own state.
    func establishIfPossible() -> EstablishOutcome {
        guard crypto == nil, let nonceIOS, let nonceMac else { return .notReady }
        guard let macPub = macPublicKey ?? Self.loadStoredMacKey() else {
            log.error("Session establishment failed: no Mac public key available")
            return .notReady
        }
        if macPublicKey == nil {
            macPublicKey = macPub
        }

        let shared: SharedSecret
        do {
            shared = try iosKey.sharedSecretFromKeyAgreement(with: macPub)
        } catch {
            log.error("Session establishment failed: key agreement: \(error.localizedDescription)")
            return .failed("Key agreement failed")
        }

        guard let session = RemoteCryptoSession.create(sharedSecret: shared, nonceMac: nonceMac, nonceIOS: nonceIOS) else {
            log.error("Session establishment failed: could not derive crypto session")
            return .failed("Session derivation failed")
        }

        crypto = session
        return .established
    }

    /// Tear down the derived session and sequencing state so a fresh
    /// handshake can run. Key material (`macPublicKey`) survives unless
    /// `clearHandshakeMaterial` also clears the nonces/pair state.
    func invalidateSession(clearHandshakeMaterial: Bool) {
        crypto = nil
        seqCounter = 1
        replayGuard.reset()
        if clearHandshakeMaterial {
            nonceIOS = nil
            nonceMac = nil
            hasReceivedPairAccept = false
        }
    }

    /// Replay-guard-ordered reset (agent re-handshake / stale key): drop the
    /// session and mint a fresh iOS nonce, keeping the Mac key.
    func resetForRehandshake() {
        crypto = nil
        seqCounter = 1
        mintIOSNonce()
    }

    private static func loadStoredMacKey() -> Curve25519.KeyAgreement.PublicKey? {
        RemotePairingStore.loadMacPublicKey()
    }
}
