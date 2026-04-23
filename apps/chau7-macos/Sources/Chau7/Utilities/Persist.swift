import Foundation

/// Logged persistence helpers that replace the `try?` + silent-drop pattern
/// found across the codebase for JSON encoding and atomic-write operations.
///
/// Three call patterns:
///   - `encodeLogged`: encode for handoff to another writer; returns nil + logs on failure.
///   - `saveLogged`: encode + atomic write in one step; returns Bool + logs on failure.
///   - `save`: same as `saveLogged` but throws `Chau7Error` so caller can surface errors.
///   - `loadLogged`: decode + distinguish "missing file" (expected) from "decode failed" (logged).
enum Persist {
    @discardableResult
    static func encodeLogged<T: Encodable>(
        _ value: T,
        context: String,
        encoder: JSONEncoder = JSONEncoder()
    ) -> Data? {
        do {
            return try encoder.encode(value)
        } catch {
            Log.error("persist.encode failed context=\(context) type=\(T.self) error=\(error)")
            return nil
        }
    }

    @discardableResult
    static func saveLogged<T: Encodable>(
        _ value: T,
        to url: URL,
        context: String,
        encoder: JSONEncoder = JSONEncoder()
    ) -> Bool {
        do {
            let data = try encoder.encode(value)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            Log.error(
                "persist.save failed context=\(context) path=\(url.path) type=\(T.self) error=\(error)"
            )
            return false
        }
    }

    static func save<T: Encodable>(
        _ value: T,
        to url: URL,
        context: String,
        encoder: JSONEncoder = JSONEncoder()
    ) throws {
        let data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            Log.error("persist.save encode failed context=\(context) type=\(T.self) error=\(error)")
            throw Chau7Error.configurationEncodeFailed(type: String(describing: T.self), underlying: error)
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            Log.error("persist.save write failed context=\(context) path=\(url.path) error=\(error)")
            throw Chau7Error.fileWriteFailed(path: url.path, underlying: error)
        }
    }

    /// Decodes `type` from in-memory `data` (e.g. a UserDefaults read).
    /// Logs on decode failure and returns nil. `data == nil` is treated as "not present"
    /// and returns nil silently (no log).
    static func decodeLogged<T: Decodable>(
        _ type: T.Type,
        from data: Data?,
        context: String,
        decoder: JSONDecoder = JSONDecoder()
    ) -> T? {
        guard let data else { return nil }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            Log.error(
                "persist.decode failed context=\(context) type=\(T.self) bytes=\(data.count) error=\(error)"
            )
            return nil
        }
    }

    /// Reads and decodes `type` from `url`. Returns:
    ///   - `.notFound` if the file does not exist (expected / first-run)
    ///   - `.loaded(value)` on success
    ///   - `.failed` if the file exists but read or decode failed (logged)
    static func loadLogged<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        context: String,
        decoder: JSONDecoder = JSONDecoder()
    ) -> LoadResult<T> {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .notFound
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            Log.error("persist.load read failed context=\(context) path=\(url.path) error=\(error)")
            return .failed
        }
        do {
            return try .loaded(decoder.decode(type, from: data))
        } catch {
            Log.error(
                "persist.load decode failed context=\(context) path=\(url.path) type=\(T.self) error=\(error)"
            )
            return .failed
        }
    }

    enum LoadResult<T> {
        case loaded(T)
        case notFound
        case failed

        var value: T? {
            if case .loaded(let v) = self { return v }
            return nil
        }
    }
}
