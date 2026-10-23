// Encrypted session state for the relay connection (shared by iOS and macOS).
//
// Uses ChaChaPoly (ChaCha20-Poly1305 AEAD) with keys derived from a Curve25519
// shared secret via HKDF-SHA256. Nonces are a 4-byte prefix plus an 8-byte
// little-endian sequence number.
//
// The nonce prefix is **direction-separated**: frames sent by iOS use a prefix
// derived with the `"nonce-ios"` label and frames sent by the Mac use
// `"nonce-mac"`. Both endpoints share one key and both start their sequence
// counter at 1, so a single shared prefix would reuse a (key, nonce) pair
// across the two directions — catastrophic for ChaCha20-Poly1305. Separate
// prefixes give each direction its own nonce space.
//
// `create` returns the **iOS perspective** (send = ios, recv = mac); the Go
// relay client mirrors it (send = mac, recv = ios).
import CryptoKit
import Foundation

public struct RemoteCryptoSession: Sendable {
    public let key: SymmetricKey
    /// Nonce prefix for frames this endpoint sends (iOS → Mac).
    public let sendNoncePrefix: Data
    /// Nonce prefix for frames this endpoint receives (Mac → iOS).
    public let recvNoncePrefix: Data

    public init(key: SymmetricKey, sendNoncePrefix: Data, recvNoncePrefix: Data) {
        self.key = key
        self.sendNoncePrefix = sendNoncePrefix
        self.recvNoncePrefix = recvNoncePrefix
    }

    public static func create(sharedSecret: SharedSecret, nonceMac: Data, nonceIOS: Data) -> RemoteCryptoSession? {
        let salt = nonceMac + nonceIOS
        let sessionKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data(),
            outputByteCount: 32
        )
        // iOS is the client: send with the ios prefix, receive with the mac one.
        return RemoteCryptoSession(
            key: sessionKey,
            sendNoncePrefix: derivePrefix(from: sharedSecret, label: "nonce-ios"),
            recvNoncePrefix: derivePrefix(from: sharedSecret, label: "nonce-mac")
        )
    }

    private static func derivePrefix(from sharedSecret: SharedSecret, label: String) -> Data {
        let prefixKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: Data(label.utf8),
            outputByteCount: 4
        )
        return prefixKey.withUnsafeBytes { Data($0) }
    }

    public func encrypt(frame: RemoteFrame) throws -> RemoteFrame {
        let nonce = try makeNonce(prefix: sendNoncePrefix, seq: frame.seq)
        // Build header with encrypted flag set and ciphertext+tag length
        let encryptedPayloadLen = UInt32(frame.payload.count + 16)
        let header = RemoteFrame(
            version: frame.version,
            type: frame.type,
            flags: frame.flags | RemoteFrame.flagEncrypted,
            reserved: frame.reserved,
            tabID: frame.tabID,
            seq: frame.seq,
            payload: Data()
        ).headerBytes(payloadLen: encryptedPayloadLen)

        let sealed = try ChaChaPoly.seal(frame.payload, using: key, nonce: nonce, authenticating: header)
        var ciphertext = sealed.ciphertext
        ciphertext.append(sealed.tag)

        return RemoteFrame(
            version: frame.version,
            type: frame.type,
            flags: frame.flags | RemoteFrame.flagEncrypted,
            reserved: frame.reserved,
            tabID: frame.tabID,
            seq: frame.seq,
            payload: ciphertext
        )
    }

    public func decrypt(frame: RemoteFrame) throws -> Data {
        guard frame.payload.count >= 16 else {
            throw RemoteCryptoError.invalidCiphertext
        }
        let header = frame.headerBytes(payloadLen: UInt32(frame.payload.count))
        let tagStart = frame.payload.count - 16
        let ciphertext = Data(frame.payload.prefix(tagStart))
        let tag = Data(frame.payload.suffix(16))
        let nonce = try makeNonce(prefix: recvNoncePrefix, seq: frame.seq)
        let sealedBox = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        return try ChaChaPoly.open(sealedBox, using: key, authenticating: header)
    }

    private func makeNonce(prefix: Data, seq: UInt64) throws -> ChaChaPoly.Nonce {
        var data = Data(count: 12)
        data.replaceSubrange(0 ..< 4, with: prefix)
        var seqLE = seq.littleEndian
        withUnsafeBytes(of: &seqLE) { buffer in
            data.replaceSubrange(4 ..< 12, with: buffer)
        }
        return try ChaChaPoly.Nonce(data: data)
    }
}

public enum RemoteCryptoError: Error, Equatable {
    case invalidCiphertext
}
