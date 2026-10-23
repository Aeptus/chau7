/// Thin wrapper around Security.framework Keychain Services.
///
/// Stores pairing keys, trusted identities, and relay credentials with
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` protection class
/// so data survives lock/unlock but never leaves the device.
import Foundation
import Security

enum KeychainStore {
    static let service = "com.chau7.remote"

    static func save(key: String, data: Data) -> Bool {
        let searchQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(searchQuery as CFDictionary, updateAttrs as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = searchQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    /// Outcome of a Keychain read. `unavailable` is distinct from `notFound`:
    /// before the first unlock after a reboot (a push-wake launch) every read
    /// fails with `errSecInteractionNotAllowed` even though the item exists.
    enum ReadResult: Equatable {
        case found(Data)
        case notFound
        case unavailable(OSStatus)
    }

    static func load(key: String) -> Data? {
        if case let .found(data) = read(key: key) {
            return data
        }
        return nil
    }

    static func read(key: String) -> ReadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return .unavailable(errSecDecode) }
            return .found(data)
        case errSecItemNotFound:
            return .notFound
        default:
            return .unavailable(status)
        }
    }

    @discardableResult
    static func delete(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
