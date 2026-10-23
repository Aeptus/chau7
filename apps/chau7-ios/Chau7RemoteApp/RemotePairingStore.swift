import Chau7Core
import CryptoKit
import Foundation
import os

private let log = Logger(subsystem: "ch7", category: "RemotePairingStore")

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

    enum DeviceKeyDecision: Equatable {
        case use(Data)
        case mint
        /// The Keychain cannot be read yet; the stored key may well exist.
        /// Minting now would replace this device's identity and break every
        /// pairing, so the caller must retry once protected data is available.
        case retryLater
    }

    static func deviceKeyDecision(for result: KeychainStore.ReadResult) -> DeviceKeyDecision {
        switch result {
        case let .found(data) where (try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)) != nil:
            .use(data)
        case .found, .notFound:
            .mint
        case .unavailable:
            .retryLater
        }
    }

    /// The persisted device key, minting and storing one on first launch.
    /// Returns nil while the Keychain is locked.
    static func loadOrCreateIOSKey() -> Curve25519.KeyAgreement.PrivateKey? {
        switch deviceKeyDecision(for: KeychainStore.read(key: Key.iosPrivateKey)) {
        case let .use(data):
            return try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
        case .mint:
            let key = Curve25519.KeyAgreement.PrivateKey()
            guard KeychainStore.save(key: Key.iosPrivateKey, data: key.rawRepresentation) else {
                log.error("Could not persist the device key; retrying on next foreground")
                return nil
            }
            return key
        case .retryLater:
            return nil
        }
    }

    private static func persist(key: String, data: Data, label: String) {
        if !KeychainStore.save(key: key, data: data) {
            log.error("Could not persist the \(label, privacy: .public) to the Keychain")
        }
    }

    // MARK: - Mac public key

    static func loadMacPublicKey() -> Curve25519.KeyAgreement.PublicKey? {
        guard let data = KeychainStore.load(key: Key.macPublicKey) else { return nil }
        return try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: data)
    }

    static func saveMacPublicKey(_ data: Data) {
        persist(key: Key.macPublicKey, data: data, label: "Mac public key")
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
        persist(key: Key.pairingPayload, data: data, label: "pairing payload")
    }

    // MARK: - Trusted identity

    static func loadTrustedIdentity() -> TrustedPairingIdentity? {
        guard let data = KeychainStore.load(key: Key.trustedIdentity) else { return nil }
        return try? RemoteJSON.decoder.decode(TrustedPairingIdentity.self, from: data)
    }

    static func saveTrustedIdentity(_ identity: TrustedPairingIdentity) {
        guard let data = try? RemoteJSON.encoder.encode(identity) else { return }
        persist(key: Key.trustedIdentity, data: data, label: "trusted identity")
    }
}
