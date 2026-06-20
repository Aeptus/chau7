import Darwin
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

    /// Appends Data using POSIX writes so I/O failures surface as errno values
    /// instead of Objective-C exceptions from FileHandle.
    @discardableResult
    static func appendData(_ data: Data, to url: URL, permissions: mode_t = 0o644) -> Bool {
        guard !data.isEmpty else { return true }

        createDirectory(at: url.deletingLastPathComponent())

        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, permissions)
        guard fd >= 0 else {
            let errorCode = errno
            Log.error("Failed to open file for append at \(url.path): \(String(cString: strerror(errorCode)))")
            return false
        }
        defer { close(fd) }

        return data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return true }
            var offset = 0

            while offset < data.count {
                let remaining = data.count - offset
                let written = Darwin.write(fd, baseAddress.advanced(by: offset), remaining)

                if written > 0 {
                    offset += written
                    continue
                }

                if written == -1, errno == EINTR {
                    continue
                }

                let errorCode = errno
                Log.error("Failed to append data to \(url.path): \(String(cString: strerror(errorCode)))")
                return false
            }

            return true
        }
    }
}

// MARK: - Safe JSON Operations

/// Helpers for JSON encoding/decoding with proper error handling
enum JSONOperations {
    /// Decodes JSON with error logging, returns nil on failure.
    /// Pass a pre-configured `decoder` to control date strategy, key strategy, etc.
    static func decode<T: Decodable>(_ type: T.Type, from data: Data, decoder: JSONDecoder? = nil, context: String = "") -> T? {
        do {
            return try (decoder ?? JSONDecoder()).decode(type, from: data)
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

    /// Encodes to JSON with error logging, returns nil on failure.
    /// Pass a pre-configured `encoder` to control formatting, date strategy, etc.
    static func encode<T: Encodable>(_ value: T, encoder: JSONEncoder? = nil, context: String = "") -> Data? {
        do {
            return try (encoder ?? JSONEncoder()).encode(value)
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
