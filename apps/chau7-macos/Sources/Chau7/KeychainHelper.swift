import Foundation
import Security

/// Secure storage for API keys using the macOS Keychain.
/// Wraps the Security framework's SecItem APIs with a clean Swift interface.
enum KeychainHelper {

    /// Saves a string value to the Keychain
    @discardableResult
    static func save(service: String, account: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else {
            Log.error("KeychainHelper: failed to encode value for \(service)/\(account)")
            return false
        }

        // Delete existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new item
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecSuccess {
            Log.info("KeychainHelper: saved \(service)/\(account)")
            return true
        } else {
            Log.error("KeychainHelper: save failed for \(service)/\(account) status=\(status)")
            return false
        }
    }

    /// Retrieves a string value from the Keychain
    static func load(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }

        return value
    }

    /// Deletes a value from the Keychain
    @discardableResult
    static func delete(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        Log.info("KeychainHelper: delete \(service)/\(account) status=\(status)")
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Checks if a value exists in the Keychain
    static func exists(service: String, account: String) -> Bool {
        load(service: service, account: account) != nil
    }
}
