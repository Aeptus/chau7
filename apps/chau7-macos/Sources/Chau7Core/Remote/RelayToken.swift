import CryptoKit
import Foundation

/// Mints scoped, single-use relay auth tokens. The format is a shared
/// contract between this client, the Go agent (`generateRelayToken`), and the
/// relay verifier (`services/chau7-relay/src/token.js`):
///
///   wire:    v2.{ts}.{nonce}.{scope}.{base64url_sig}
///   message: v2:{deviceID}:{role}:{scope}:{ts}:{nonce}
///
/// `make(pairing:role:scope:)` returns nil when the pairing payload carries no
/// relay secret, so the client degrades to unauthenticated connects during
/// rollout.
public enum RelayToken {
    public static func make(pairing: RemotePairingPayload, role: String, scope: String) -> String? {
        guard let secret = pairing.relaySecret, !secret.isEmpty else {
            return nil
        }
        var nonceBytes = [UInt8](repeating: 0, count: 16)
        for index in nonceBytes.indices {
            nonceBytes[index] = UInt8.random(in: UInt8.min ... UInt8.max)
        }
        return make(
            deviceID: pairing.deviceID,
            secret: secret,
            role: role,
            scope: scope,
            ts: String(Int(Date().timeIntervalSince1970)),
            nonce: Data(nonceBytes).relayBase64URLEncodedString()
        )
    }

    /// Deterministic core, exposed for tests that mirror the Go/relay vectors.
    static func make(
        deviceID: String,
        secret: String,
        role: String,
        scope: String,
        ts: String,
        nonce: String
    ) -> String {
        let message = "v2:\(deviceID):\(role):\(scope):\(ts):\(nonce)"
        let key = SymmetricKey(data: Data(secret.utf8))
        let signature = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        let signatureString = Data(signature).relayBase64URLEncodedString()
        return "v2.\(ts).\(nonce).\(scope).\(signatureString)"
    }
}

extension Data {
    /// Unpadded base64url (RFC 4648 §5), matching the relay's expectations.
    func relayBase64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
