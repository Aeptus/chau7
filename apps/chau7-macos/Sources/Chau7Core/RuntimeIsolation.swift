import Foundation

public enum RuntimeIsolation {
    private static let keychainPrefixKey = "CHAU7_KEYCHAIN_SERVICE_PREFIX"
    private static let homeRootKey = "CHAU7_HOME_ROOT"
    private static let isolatedTestModeKey = "CHAU7_ISOLATED_TEST_MODE"

    public static func keychainServiceName(
        base: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let prefix = environment[keychainPrefixKey]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !prefix.isEmpty else { return base }
        return "\(prefix).\(base)"
    }

    public static func isIsolatedTestMode(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let raw = environment[isolatedTestModeKey]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw == "1" || raw.caseInsensitiveCompare("true") == .orderedSame
    }

    public static func homeDirectory(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = normalizedHomeRoot(from: environment) {
            return override
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL
    }

    public static func homePath(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        homeDirectory(fileManager: fileManager, environment: environment).path
    }

    public static func libraryDirectory(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        homeDirectory(fileManager: fileManager, environment: environment)
            .appendingPathComponent("Library", isDirectory: true)
    }

    public static func applicationSupportDirectory(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if normalizedHomeRoot(from: environment) != nil {
            return libraryDirectory(fileManager: fileManager, environment: environment)
                .appendingPathComponent("Application Support", isDirectory: true)
        }
        return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? libraryDirectory(fileManager: fileManager, environment: environment)
            .appendingPathComponent("Application Support", isDirectory: true)
    }

    public static func logsDirectory(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        libraryDirectory(fileManager: fileManager, environment: environment)
            .appendingPathComponent("Logs", isDirectory: true)
    }

    public static func chau7Directory(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        homeDirectory(fileManager: fileManager, environment: environment)
            .appendingPathComponent(".chau7", isDirectory: true)
    }

    public static func appSupportDirectory(
        named name: String,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        applicationSupportDirectory(fileManager: fileManager, environment: environment)
            .appendingPathComponent(name, isDirectory: true)
    }

    public static func pathInHome(
        _ relativePath: String,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        urlInHome(relativePath, fileManager: fileManager, environment: environment).path
    }

    public static func urlInHome(
        _ relativePath: String,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return homeDirectory(fileManager: fileManager, environment: environment)
        }
        let sanitized = trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
        return homeDirectory(fileManager: fileManager, environment: environment)
            .appendingPathComponent(sanitized, isDirectory: false)
    }

    public static func expandTilde(
        in path: String,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        guard path.hasPrefix("~/") else { return path }
        return homePath(fileManager: fileManager, environment: environment) + String(path.dropFirst())
    }

    private static func normalizedHomeRoot(from environment: [String: String]) -> URL? {
        let raw = environment[homeRootKey]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return nil }
        return URL(fileURLWithPath: raw).standardizedFileURL
    }
}
