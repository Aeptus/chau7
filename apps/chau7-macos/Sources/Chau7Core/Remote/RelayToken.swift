import CryptoKit
import Foundation

/// Mints single-use v3 tokens using a provisioned device/role credential.
/// wire: v3.{keyID}.{ts}.{nonce}.{scope}.{signature}
/// message: v3:{keyID}:{deviceID}:{role}:{scope}:{ts}:{nonce}
public enum RelayToken {
    public static func isStrongCredential(_ value: String) -> Bool {
        guard value.count == 43, value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
              let bytes = Data(base64Encoded: value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="),
              bytes.count == 32 else { return false }
        return bytes.relayBase64URLEncodedString() == value
    }

    public static func isValidIdentifier(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.count <= maximum && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    public static func make(pairing: RemotePairingPayload, role: String, scope: String) -> String? {
        guard role == "ios", let secret = pairing.relaySecret, let keyID = pairing.relayKeyID else { return nil }
        return make(deviceID: pairing.deviceID, keyID: keyID, secret: secret, role: role, scope: scope)
    }

    public static func make(deviceID: String, keyID: String, secret: String, role: String, scope: String) -> String? {
        guard isValidIdentifier(deviceID, maximum: 128), isValidIdentifier(keyID, maximum: 32), isStrongCredential(secret),
              ["mac", "ios"].contains(role), ["connect", "push", "pending", "issues"].contains(scope) else { return nil }
        var nonceBytes = [UInt8](repeating: 0, count: 16)
        for index in nonceBytes.indices {
            nonceBytes[index] = UInt8.random(in: UInt8.min ... UInt8.max)
        }
        return make(
            deviceID: deviceID,
            keyID: keyID,
            secret: secret,
            role: role,
            scope: scope,
            ts: String(Int(Date().timeIntervalSince1970)),
            nonce: Data(nonceBytes).relayBase64URLEncodedString()
        )
    }

    /// Deterministic signature core; callers validate credential metadata first.
    static func make(deviceID: String, keyID: String, secret: String, role: String, scope: String, ts: String, nonce: String) -> String {
        let message = "v3:\(keyID):\(deviceID):\(role):\(scope):\(ts):\(nonce)"
        let signature = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(secret.utf8)))
        return "v3.\(keyID).\(ts).\(nonce).\(scope).\(Data(signature).relayBase64URLEncodedString())"
    }
}

extension Data {
    func relayBase64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
