import Foundation

// MARK: - Typed Errors for Chau7

/// Application-wide error types for better error handling and debugging
enum Chau7Error: LocalizedError {
    // File operations
    case directoryCreationFailed(path: String, underlying: Error)
    case fileReadFailed(path: String, underlying: Error)
    case fileWriteFailed(path: String, underlying: Error)
    case fileNotFound(path: String)

    // Configuration
    case configurationDecodeFailed(type: String, underlying: Error)
    case configurationEncodeFailed(type: String, underlying: Error)
    case invalidConfiguration(reason: String)

    // Terminal
    case terminalNotAttached
    case shellStartFailed(reason: String)
    case processSpawnFailed(executable: String, underlying: Error?)

    // Snippets
    case snippetNotFound(id: String)
    case snippetSaveFailed(underlying: Error)
    case snippetLoadFailed(path: String, underlying: Error)

    // Settings
    case settingsImportFailed(reason: String)
    case settingsExportFailed(reason: String)
    case profileNotFound(name: String)

    // SSH Operations (new)
    case sshConnectionFailed(host: String, reason: String)
    case sshInvalidHost(host: String)
    case sshInvalidPort(port: Int)
    case sshKeyNotFound(path: String)
    case sshUnsafeOptions(options: String, reason: String)

    // Clipboard Operations (new)
    case clipboardAccessDenied
    case clipboardRateLimited(retryAfter: TimeInterval)
    case clipboardDataCorrupted

    // Security (new)
    case securityViolation(reason: String)
    case inputValidationFailed(field: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .directoryCreationFailed(let path, let error):
            return "Failed to create directory at \(path): \(error.localizedDescription)"
        case .fileReadFailed(let path, let error):
            return "Failed to read file at \(path): \(error.localizedDescription)"
        case .fileWriteFailed(let path, let error):
            return "Failed to write file at \(path): \(error.localizedDescription)"
        case .fileNotFound(let path):
            return "File not found: \(path)"

        case .configurationDecodeFailed(let type, let error):
            return "Failed to decode \(type): \(error.localizedDescription)"
        case .configurationEncodeFailed(let type, let error):
            return "Failed to encode \(type): \(error.localizedDescription)"
        case .invalidConfiguration(let reason):
            return "Invalid configuration: \(reason)"

        case .terminalNotAttached:
            return "Terminal view not attached to session"
        case .shellStartFailed(let reason):
            return "Failed to start shell: \(reason)"
        case .processSpawnFailed(let executable, let error):
            if let error = error {
                return "Failed to spawn process \(executable): \(error.localizedDescription)"
            }
            return "Failed to spawn process: \(executable)"

        case .snippetNotFound(let id):
            return "Snippet not found: \(id)"
        case .snippetSaveFailed(let error):
            return "Failed to save snippet: \(error.localizedDescription)"
        case .snippetLoadFailed(let path, let error):
            return "Failed to load snippets from \(path): \(error.localizedDescription)"

        case .settingsImportFailed(let reason):
            return "Failed to import settings: \(reason)"
        case .settingsExportFailed(let reason):
            return "Failed to export settings: \(reason)"
        case .profileNotFound(let name):
            return "Settings profile not found: \(name)"

        // SSH
        case .sshConnectionFailed(let host, let reason):
            return "Failed to connect to \(host): \(reason)"
        case .sshInvalidHost(let host):
            return "Invalid SSH host: \(host)"
        case .sshInvalidPort(let port):
            return "Invalid SSH port: \(port). Port must be between 1 and 65535."
        case .sshKeyNotFound(let path):
            return "SSH identity file not found: \(path)"
        case .sshUnsafeOptions(let options, let reason):
            return "Unsafe SSH options blocked: \(options). \(reason)"

        // Clipboard
        case .clipboardAccessDenied:
            return "Clipboard access denied by system"
        case .clipboardRateLimited(let retryAfter):
            return "Clipboard rate limited. Please wait \(Int(retryAfter)) seconds."
        case .clipboardDataCorrupted:
            return "Clipboard data is corrupted or unreadable"

        // Security
        case .securityViolation(let reason):
            return "Security violation: \(reason)"
        case .inputValidationFailed(let field, let reason):
            return "Invalid input for \(field): \(reason)"
        }
    }

    /// Provides recovery suggestions for each error type
    var recoverySuggestion: String? {
        switch self {
        case .directoryCreationFailed:
            return "Check that the parent directory exists and you have write permissions."
        case .fileReadFailed:
            return "Ensure the file exists and you have read permissions."
        case .fileWriteFailed:
            return "Check that the destination is writable and has sufficient disk space."
        case .fileNotFound:
            return "Verify the file path is correct and the file exists."

        case .configurationDecodeFailed:
            return "The configuration file may be corrupted. Try resetting to defaults."
        case .configurationEncodeFailed:
            return "There may be an internal error. Please report this issue."
        case .invalidConfiguration:
            return "Check the configuration values and try again."

        case .terminalNotAttached:
            return "Wait for the terminal to fully initialize before performing this action."
        case .shellStartFailed:
            return "Check that the shell path is valid and the shell is installed."
        case .processSpawnFailed:
            return "Verify the executable exists and you have permission to run it."

        case .snippetNotFound:
            return "The snippet may have been deleted. Refresh the snippet list."
        case .snippetSaveFailed:
            return "Check that you have write permissions to the snippets directory."
        case .snippetLoadFailed:
            return "The snippets file may be corrupted. Try restoring from backup."

        case .settingsImportFailed:
            return "Ensure the settings file is a valid Chau7 settings export."
        case .settingsExportFailed:
            return "Check that the destination is writable."
        case .profileNotFound:
            return "The profile may have been deleted. Choose a different profile."

        case .sshConnectionFailed:
            return "Verify the host is reachable and SSH is enabled. Check your credentials."
        case .sshInvalidHost:
            return "Enter a valid hostname or IP address."
        case .sshInvalidPort:
            return "Enter a port number between 1 and 65535. The default SSH port is 22."
        case .sshKeyNotFound:
            return "Check that the identity file path is correct. Common locations: ~/.ssh/id_rsa, ~/.ssh/id_ed25519"
        case .sshUnsafeOptions:
            return "Some SSH options are blocked for security. Use safe options only."

        case .clipboardAccessDenied:
            return "Grant Chau7 clipboard access in System Settings > Privacy & Security."
        case .clipboardRateLimited:
            return "The clipboard is being accessed too frequently. Wait and try again."
        case .clipboardDataCorrupted:
            return "Clear the clipboard and try copying again."

        case .securityViolation:
            return "This action was blocked for security reasons."
        case .inputValidationFailed:
            return "Check the input value and ensure it meets the requirements."
        }
    }
}

// MARK: - Logging Helpers

extension Chau7Error {
    /// Logs the error and returns nil - useful for converting throwing code to optional
    @discardableResult
    func logged() -> Self {
        Log.error(errorDescription ?? "Unknown error")
        return self
    }
}

// MARK: - Safe File Operations

/// Helpers for file operations with proper error handling
enum FileOperations {
    /// Creates a directory, logging any errors
    /// Returns true if successful or directory already exists
    @discardableResult
    static func createDirectory(at url: URL, withIntermediateDirectories: Bool = true) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories)
            return true
        } catch {
            // Don't log if directory already exists
            if (error as NSError).code != NSFileWriteFileExistsError {
                Log.warn("Failed to create directory at \(url.path): \(error.localizedDescription)")
            }
            return FileManager.default.fileExists(atPath: url.path)
        }
    }

    /// Creates a directory at path, logging any errors
    @discardableResult
    static func createDirectory(atPath path: String, withIntermediateDirectories: Bool = true) -> Bool {
        createDirectory(at: URL(fileURLWithPath: path), withIntermediateDirectories: withIntermediateDirectories)
    }

    /// Reads file contents with error logging
    static func readString(from path: String, encoding: String.Encoding = .utf8) -> String? {
        do {
            return try String(contentsOfFile: path, encoding: encoding)
        } catch {
            Log.warn("Failed to read file at \(path): \(error.localizedDescription)")
            return nil
        }
    }

    /// Writes string to file with error logging
    @discardableResult
    static func writeString(_ content: String, to path: String, atomically: Bool = true, encoding: String.Encoding = .utf8) -> Bool {
        do {
            try content.write(toFile: path, atomically: atomically, encoding: encoding)
            return true
        } catch {
            Log.error("Failed to write file at \(path): \(error.localizedDescription)")
            return false
        }
    }

    /// Reads Data from URL with error logging
    static func readData(from url: URL) -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch {
            Log.warn("Failed to read data from \(url.path): \(error.localizedDescription)")
            return nil
        }
    }

    /// Writes Data to URL with error logging
    @discardableResult
    static func writeData(_ data: Data, to url: URL, options: Data.WritingOptions = []) -> Bool {
        do {
            try data.write(to: url, options: options)
            return true
        } catch {
            Log.error("Failed to write data to \(url.path): \(error.localizedDescription)")
            return false
        }
    }
}

// MARK: - Safe JSON Operations

/// Helpers for JSON encoding/decoding with proper error handling
enum JSONOperations {
    /// Decodes JSON with error logging, returns nil on failure
    static func decode<T: Decodable>(_ type: T.Type, from data: Data, context: String = "") -> T? {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            let typeName = String(describing: type)
            if context.isEmpty {
                Log.warn("Failed to decode \(typeName): \(error.localizedDescription)")
            } else {
                Log.warn("Failed to decode \(typeName) (\(context)): \(error.localizedDescription)")
            }
            return nil
        }
    }

    /// Encodes to JSON with error logging, returns nil on failure
    static func encode<T: Encodable>(_ value: T, context: String = "") -> Data? {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            let typeName = String(describing: T.self)
            if context.isEmpty {
                Log.warn("Failed to encode \(typeName): \(error.localizedDescription)")
            } else {
                Log.warn("Failed to encode \(typeName) (\(context)): \(error.localizedDescription)")
            }
            return nil
        }
    }

    /// Parses JSON data into a dictionary with error logging, returns nil on failure
    static func parseJSON(from data: Data, context: String = "") -> [String: Any]? {
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                if context.isEmpty {
                    Log.trace("JSON parse result was not a dictionary")
                } else {
                    Log.trace("JSON parse result was not a dictionary (\(context))")
                }
                return nil
            }
            return json
        } catch {
            if context.isEmpty {
                Log.trace("Failed to parse JSON: \(error.localizedDescription)")
            } else {
                Log.trace("Failed to parse JSON (\(context)): \(error.localizedDescription)")
            }
            return nil
        }
    }
}

// MARK: - Rate Limiter

/// Thread-safe rate limiter for protecting against abuse
final class RateLimiter {
    private let maxRequests: Int
    private let windowSeconds: TimeInterval
    private var timestamps: [Date] = []
    private let lock = NSLock()

    /// Creates a rate limiter
    /// - Parameters:
    ///   - maxRequests: Maximum number of requests allowed in the time window
    ///   - windowSeconds: Time window in seconds
    init(maxRequests: Int, windowSeconds: TimeInterval) {
        self.maxRequests = maxRequests
        self.windowSeconds = windowSeconds
    }

    /// Checks if an action is allowed under the rate limit
    /// - Returns: True if the action is allowed, false if rate limited
    func isAllowed() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        let windowStart = now.addingTimeInterval(-windowSeconds)

        // Remove timestamps outside the window
        timestamps = timestamps.filter { $0 > windowStart }

        if timestamps.count < maxRequests {
            timestamps.append(now)
            return true
        }

        return false
    }

    /// Returns the time until the next action is allowed
    /// - Returns: Time interval in seconds, or 0 if action is allowed now
    func timeUntilAllowed() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        let windowStart = now.addingTimeInterval(-windowSeconds)

        timestamps = timestamps.filter { $0 > windowStart }

        if timestamps.count < maxRequests {
            return 0
        }

        // Return time until oldest timestamp exits the window
        guard let oldest = timestamps.first else { return 0 }
        return oldest.timeIntervalSince(windowStart)
    }

    /// Resets the rate limiter
    func reset() {
        lock.lock()
        timestamps.removeAll()
        lock.unlock()
    }
}

// MARK: - Input Validation

/// Utilities for validating user input
enum InputValidation {

    /// Validates a hostname or IP address
    /// - Parameter host: The hostname to validate
    /// - Returns: Result with success or validation error
    static func validateHost(_ host: String) -> Result<String, Chau7Error> {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            return .failure(.inputValidationFailed(field: "host", reason: "Host cannot be empty"))
        }

        // Check for dangerous characters
        let dangerous = CharacterSet(charactersIn: ";|&`$(){}[]\\'\"\n\r\t")
        if trimmed.rangeOfCharacter(from: dangerous) != nil {
            return .failure(.inputValidationFailed(field: "host", reason: "Host contains invalid characters"))
        }

        // Basic format check (hostname or IP)
        let hostnameRegex = #"^[a-zA-Z0-9]([a-zA-Z0-9\-\.]*[a-zA-Z0-9])?$"#
        let ipRegex = #"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$"#

        let isHostname = trimmed.range(of: hostnameRegex, options: .regularExpression) != nil
        let isIP = trimmed.range(of: ipRegex, options: .regularExpression) != nil

        if !isHostname && !isIP {
            return .failure(.sshInvalidHost(host: trimmed))
        }

        return .success(trimmed)
    }

    /// Validates a port number
    /// - Parameter port: The port to validate
    /// - Returns: Result with success or validation error
    static func validatePort(_ port: Int) -> Result<Int, Chau7Error> {
        if port < 1 || port > 65535 {
            return .failure(.sshInvalidPort(port: port))
        }
        return .success(port)
    }

    /// Validates a file path for safety
    /// - Parameter path: The path to validate
    /// - Returns: Result with sanitized path or validation error
    static func validatePath(_ path: String) -> Result<String, Chau7Error> {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            return .failure(.inputValidationFailed(field: "path", reason: "Path cannot be empty"))
        }

        // Check for null bytes (path traversal attack)
        if trimmed.contains("\0") {
            return .failure(.securityViolation(reason: "Path contains null byte"))
        }

        // Check for command substitution
        if trimmed.contains("$(") || trimmed.contains("`") {
            return .failure(.securityViolation(reason: "Path contains command substitution"))
        }

        return .success(trimmed)
    }

    /// Validates a username
    /// - Parameter username: The username to validate
    /// - Returns: Result with success or validation error
    static func validateUsername(_ username: String) -> Result<String, Chau7Error> {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            return .failure(.inputValidationFailed(field: "username", reason: "Username cannot be empty"))
        }

        // Check for dangerous characters
        let dangerous = CharacterSet(charactersIn: ";|&`$(){}[]\\'\"\n\r\t @")
        if trimmed.rangeOfCharacter(from: dangerous) != nil {
            return .failure(.inputValidationFailed(field: "username", reason: "Username contains invalid characters"))
        }

        return .success(trimmed)
    }
}
