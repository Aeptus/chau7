import CryptoKit
import XCTest
@testable import Chau7Core

final class RemoteCryptoSessionTests: XCTestCase {
    // Deterministic shared secret + nonces so the derivations are reproducible.
    private func makeSharedSecret() throws -> SharedSecret {
        let priv = Curve25519.KeyAgreement.PrivateKey()
        let peer = Curve25519.KeyAgreement.PrivateKey()
        return try priv.sharedSecretFromKeyAgreement(with: peer.publicKey)
    }

    /// Builds the iOS-perspective session and a mirrored Mac-perspective session
    /// (send/recv prefixes swapped) so both directions can be exercised.
    private func makeSessionPair() throws -> (ios: RemoteCryptoSession, mac: RemoteCryptoSession) {
        let shared = try makeSharedSecret()
        let nonceMac = Data(repeating: 0xA1, count: 16)
        let nonceIOS = Data(repeating: 0xB2, count: 16)
        let ios = try XCTUnwrap(
            RemoteCryptoSession.create(sharedSecret: shared, nonceMac: nonceMac, nonceIOS: nonceIOS)
        )
        let mac = RemoteCryptoSession(
            key: ios.key,
            sendNoncePrefix: ios.recvNoncePrefix,
            recvNoncePrefix: ios.sendNoncePrefix
        )
        return (ios, mac)
    }

    private func frame(seq: UInt64, payload: Data) -> RemoteFrame {
        RemoteFrame(type: RemoteFrameType.output.rawValue, tabID: 7, seq: seq, payload: payload)
    }

    func testDirectionPrefixesDiffer() throws {
        let (ios, _) = try makeSessionPair()
        XCTAssertEqual(ios.sendNoncePrefix.count, 4)
        XCTAssertEqual(ios.recvNoncePrefix.count, 4)
        XCTAssertNotEqual(
            ios.sendNoncePrefix, ios.recvNoncePrefix,
            "Send/receive nonce prefixes must differ to avoid cross-direction nonce reuse"
        )
    }

    func testRoundTripIOSToMac() throws {
        let (ios, mac) = try makeSessionPair()
        let payload = Data("ls -la /Users/me".utf8)
        let encrypted = try ios.encrypt(frame: frame(seq: 1, payload: payload))
        XCTAssertNotEqual(encrypted.flags & RemoteFrame.flagEncrypted, 0)
        let decrypted = try mac.decrypt(frame: encrypted)
        XCTAssertEqual(decrypted, payload)
    }

    func testRoundTripMacToIOS() throws {
        let (ios, mac) = try makeSessionPair()
        let payload = Data("approval granted".utf8)
        let encrypted = try mac.encrypt(frame: frame(seq: 1, payload: payload))
        let decrypted = try ios.decrypt(frame: encrypted)
        XCTAssertEqual(decrypted, payload)
    }

    func testSameSeqDifferentDirectionsProduceDifferentCiphertext() throws {
        // The core nonce-reuse guarantee: identical plaintext + identical seq in
        // the two directions must not yield the same keystream/ciphertext.
        let (ios, mac) = try makeSessionPair()
        let payload = Data(repeating: 0x5A, count: 64)
        let fromIOS = try ios.encrypt(frame: frame(seq: 1, payload: payload))
        let fromMac = try mac.encrypt(frame: frame(seq: 1, payload: payload))
        XCTAssertNotEqual(fromIOS.payload, fromMac.payload)
    }

    func testDecryptingOwnFrameFailsBecausePrefixesDiffer() throws {
        // A session encrypts with send prefix and decrypts with recv prefix, so
        // decrypting its own output must fail (also guards against accidentally
        // collapsing the two prefixes back together).
        let (ios, _) = try makeSessionPair()
        let encrypted = try ios.encrypt(frame: frame(seq: 1, payload: Data("x".utf8)))
        XCTAssertThrowsError(try ios.decrypt(frame: encrypted))
    }

    func testTamperedCiphertextIsRejected() throws {
        let (ios, mac) = try makeSessionPair()
        var encrypted = try ios.encrypt(frame: frame(seq: 1, payload: Data("secret".utf8)))
        var bytes = encrypted.payload
        // `encrypted.payload` originates from CryptoKit's SealedBox.ciphertext,
        // which can be a slice with a non-zero startIndex — `bytes[0]` would be
        // out of bounds and trap. Index relative to startIndex.
        bytes[bytes.startIndex] ^= 0xFF
        encrypted = RemoteFrame(
            version: encrypted.version,
            type: encrypted.type,
            flags: encrypted.flags,
            reserved: encrypted.reserved,
            tabID: encrypted.tabID,
            seq: encrypted.seq,
            payload: bytes
        )
        XCTAssertThrowsError(try mac.decrypt(frame: encrypted))
    }

    func testShortCiphertextIsRejected() throws {
        let (_, mac) = try makeSessionPair()
        let tooShort = RemoteFrame(
            type: RemoteFrameType.output.rawValue,
            tabID: 0,
            seq: 1,
            payload: Data([0x00, 0x01])
        )
        XCTAssertThrowsError(try mac.decrypt(frame: tooShort)) { error in
            XCTAssertEqual(error as? RemoteCryptoError, .invalidCiphertext)
        }
    }
}
