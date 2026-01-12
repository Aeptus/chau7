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
