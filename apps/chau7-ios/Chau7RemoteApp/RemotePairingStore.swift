import Chau7Core
import CryptoKit
import Foundation

/// Keychain-backed persistence for pairing material: the device's long-lived
/// Curve25519 private key, the paired Mac's public key, the pairing payload, and
/// the trusted-identity record used for silent reconnects.
///
/// Extracted from `RemoteClient` so that key storage (and the raw Keychain
/// account names) live behind one cohesive type instead of being scattered
/// through the connection logic as inline string literals.
enum RemotePairingStore {
    private enum Key {
        static let iosPrivateKey = "ios_private_key"
        static let macPublicKey = "mac_public_key"
        static let pairingPayload = "pairing_payload"
        static let trustedIdentity = "trusted_pairing_identity"
    }

    // MARK: - Device key

    static func loadOrCreateIOSKey() -> Curve25519.KeyAgreement.PrivateKey {
        if let data = KeychainStore.load(key: Key.iosPrivateKey),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        _ = KeychainStore.save(key: Key.iosPrivateKey, data: key.rawRepresentation)
        return key
    }

    // MARK: - Mac public key

    static func loadMacPublicKey() -> Curve25519.KeyAgreement.PublicKey? {
        guard let data = KeychainStore.load(key: Key.macPublicKey) else { return nil }
        return try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: data)
    }

    static func saveMacPublicKey(_ data: Data) {
        _ = KeychainStore.save(key: Key.macPublicKey, data: data)
    }

    // MARK: - Pairing payload

    static func loadPairing() -> PairingInfo? {
        guard let data = KeychainStore.load(key: Key.pairingPayload) else { return nil }
        return try? RemoteJSON.decoder.decode(PairingInfo.self, from: data)
    }

    /// Persists the pairing payload, or clears both the payload and trusted
    /// identity when `info` is `nil` (the two are only valid together).
    static func savePairing(_ info: PairingInfo?) {
        guard let info, let data = try? RemoteJSON.encoder.encode(info) else {
            _ = KeychainStore.delete(key: Key.pairingPayload)
            _ = KeychainStore.delete(key: Key.trustedIdentity)
            return
        }
        _ = KeychainStore.save(key: Key.pairingPayload, data: data)
    }

    // MARK: - Trusted identity

    static func loadTrustedIdentity() -> TrustedPairingIdentity? {
        guard let data = KeychainStore.load(key: Key.trustedIdentity) else { return nil }
        return try? RemoteJSON.decoder.decode(TrustedPairingIdentity.self, from: data)
    }

    static func saveTrustedIdentity(_ identity: TrustedPairingIdentity) {
        guard let data = try? RemoteJSON.encoder.encode(identity) else { return }
        _ = KeychainStore.save(key: Key.trustedIdentity, data: data)
    }
}
