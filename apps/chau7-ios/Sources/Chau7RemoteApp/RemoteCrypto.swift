import Foundation
import CryptoKit

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
        let prefixKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: sharedSecret,
            salt: Data(),
            info: Data("nonce".utf8),
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
        guard let combined = sealed.combined else {
            throw RemoteCryptoError.invalidCiphertext
        }
        encrypted.payload = combined
        return encrypted
    }

    func decrypt(frame: RemoteFrame) throws -> Data {
        let nonce = try makeNonce(prefix: noncePrefix, seq: frame.seq)
        let header = frame.headerBytes(payloadLen: UInt32(frame.payload.count))
        let sealedBox = try ChaChaPoly.SealedBox(combined: frame.payload)
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
