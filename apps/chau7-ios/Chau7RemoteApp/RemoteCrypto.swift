import Foundation
import CryptoKit
import Chau7Core

struct RemoteCryptoSession {
    let key: SymmetricKey
    let noncePrefix: Data

    static func create(sharedSecret: SharedSecret, nonceMac: Data, nonceIOS: Data) -> RemoteCryptoSession? {
        let salt = nonceMac + nonceIOS
        let sessionKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data(),
            outputByteCount: 32
        )
        let prefixKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: Data("nonce".utf8),
            outputByteCount: 4
        )
        let prefix = prefixKey.withUnsafeBytes { Data($0) }
        return RemoteCryptoSession(key: sessionKey, noncePrefix: prefix)
    }

    func encrypt(frame: RemoteFrame) throws -> RemoteFrame {
        var encrypted = frame
        encrypted.flags |= RemoteFrame.flagEncrypted
        let nonce = try makeNonce(prefix: noncePrefix, seq: frame.seq)
        let payloadLen = UInt32(frame.payload.count + 16)
        let header = encrypted.headerBytes(payloadLen: payloadLen)
        let sealed = try ChaChaPoly.seal(frame.payload, using: key, nonce: nonce, authenticating: header)
        var combined = sealed.ciphertext
        combined.append(sealed.tag)
        encrypted.payload = combined
        return encrypted
    }

    func decrypt(frame: RemoteFrame) throws -> Data {
        let header = frame.headerBytes(payloadLen: UInt32(frame.payload.count))
        guard frame.payload.count >= 16 else {
            throw RemoteCryptoError.invalidCiphertext
        }
        let tagStart = frame.payload.count - 16
        let ciphertext = Data(frame.payload.prefix(tagStart))
        let tag = Data(frame.payload.suffix(16))
        let nonce = try makeNonce(prefix: noncePrefix, seq: frame.seq)
        let sealedBox = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        return try ChaChaPoly.open(sealedBox, using: key, authenticating: header)
    }

    private func makeNonce(prefix: Data, seq: UInt64) throws -> ChaChaPoly.Nonce {
        var data = Data(count: 12)
        data.replaceSubrange(0..<4, with: prefix)
        var seqLE = seq.littleEndian
        withUnsafeBytes(of: &seqLE) { buffer in
            data.replaceSubrange(4..<12, with: buffer)
        }
        return try ChaChaPoly.Nonce(data: data)
    }
}

enum RemoteCryptoError: Error {
    case invalidCiphertext
}
