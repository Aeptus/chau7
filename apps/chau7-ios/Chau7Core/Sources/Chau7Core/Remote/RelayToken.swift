import CryptoKit
import Foundation

/// Mints single-use relay tokens.
///
/// v3, signed with the credential every phone of a Mac shares:
/// wire: v3.{keyID}.{ts}.{nonce}.{scope}.{signature}
/// message: v3:{keyID}:{deviceID}:{role}:{scope}:{ts}:{nonce}
///
/// v4, signed with a credential for one phone or one pairing window:
/// wire: v4.{keyID}.{phoneID}.{ts}.{nonce}.{scope}.{signature}
/// message: v4:{keyID}:{deviceID}:{role}:{phoneID}:{scope}:{ts}:{nonce}
public enum RelayToken {
    /// Which credential signs a token, best first: this phone's own; the
    /// pairing-window one from a QR while that window is open; the shared one.
    enum Signer: Equatable {
        case phone(id: String, keyID: String, secret: String)
        case shared(keyID: String, secret: String)
    }

    static func signer(
        pairing: RemotePairingPayload,
        phoneCredential: RemotePhoneRelayCredential?,
        now: Date
    ) -> Signer? {
        if let phoneCredential, phoneCredential.deviceID == pairing.deviceID, phoneCredential.credential.isWellFormed {
            let credential = phoneCredential.credential
            return .phone(id: credential.phoneID, keyID: credential.relayKeyID, secret: credential.relaySecret)
        }
        guard let keyID = pairing.relayKeyID else { return nil }
        if let pairID = pairing.relayPairID, let pairSecret = pairing.relayPairSecret,
           isStrongCredential(pairSecret), let closes = pairWindowClose(pairID), closes > now {
            return .phone(id: pairID, keyID: keyID, secret: pairSecret)
        }
        guard let secret = pairing.relaySecret else { return nil }
        return .shared(keyID: keyID, secret: secret)
    }

    /// When a pairing-window label (`p` + unix seconds) stops working.
    static func pairWindowClose(_ label: String) -> Date? {
        guard label.first == "p", label.count <= 13, let seconds = TimeInterval(label.dropFirst()),
              label.dropFirst().allSatisfy(\.isNumber) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    public static func isStrongCredential(_ value: String) -> Bool {
        guard value.count == 43, value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
              let bytes = Data(base64Encoded: value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="),
              bytes.count == 32 else { return false }
        return bytes.relayBase64URLEncodedString() == value
    }

    public static func isValidIdentifier(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.count <= maximum && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    public static func make(
        pairing: RemotePairingPayload,
        phoneCredential: RemotePhoneRelayCredential? = nil,
        role: String,
        scope: String,
        now: Date = Date()
    ) -> String? {
        guard role == "ios", let signer = signer(pairing: pairing, phoneCredential: phoneCredential, now: now) else { return nil }
        switch signer {
        case let .shared(keyID, secret):
            return make(deviceID: pairing.deviceID, keyID: keyID, secret: secret, role: role, scope: scope)
        case let .phone(id, keyID, secret):
            return make(deviceID: pairing.deviceID, keyID: keyID, phoneID: id, secret: secret, role: role, scope: scope)
        }
    }

    public static func make(
        deviceID: String,
        keyID: String,
        phoneID: String? = nil,
        secret: String,
        role: String,
        scope: String
    ) -> String? {
        guard isValidIdentifier(deviceID, maximum: 128), isValidIdentifier(keyID, maximum: 32), isStrongCredential(secret),
              phoneID.map({ isValidIdentifier($0, maximum: 32) }) ?? true,
              ["mac", "ios"].contains(role), ["connect", "push", "pending", "issues"].contains(scope) else { return nil }
        var nonceBytes = [UInt8](repeating: 0, count: 16)
        for index in nonceBytes.indices {
            nonceBytes[index] = UInt8.random(in: UInt8.min ... UInt8.max)
        }
        return make(
            deviceID: deviceID,
            keyID: keyID,
            phoneID: phoneID,
            secret: secret,
            role: role,
            scope: scope,
            ts: String(Int(Date().timeIntervalSince1970)),
            nonce: Data(nonceBytes).relayBase64URLEncodedString()
        )
    }

    /// Deterministic signature core; callers validate credential metadata first.
    static func make(
        deviceID: String,
        keyID: String,
        phoneID: String? = nil,
        secret: String,
        role: String,
        scope: String,
        ts: String,
        nonce: String
    ) -> String {
        let message = if let phoneID {
            "v4:\(keyID):\(deviceID):\(role):\(phoneID):\(scope):\(ts):\(nonce)"
        } else {
            "v3:\(keyID):\(deviceID):\(role):\(scope):\(ts):\(nonce)"
        }
        let signature = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(secret.utf8)))
        let prefix = phoneID.map { "v4.\(keyID).\($0)" } ?? "v3.\(keyID)"
        return "\(prefix).\(ts).\(nonce).\(scope).\(Data(signature).relayBase64URLEncodedString())"
    }
}

extension Data {
    func relayBase64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
