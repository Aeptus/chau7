import Foundation
import Darwin

final class RustEscapeSanitizer {
    static let shared = RustEscapeSanitizer()

    private typealias Sanitize = @convention(c) (UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
    private typealias FreeString = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void

    private struct Functions {
        let sanitize: Sanitize
        let freeString: FreeString
    }

    private let lock = NSLock()
    private var loadAttempted = false
    private var functions: Functions?

    private init() {}

    func sanitize(_ text: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard ensureLoadedUnlocked() else { return nil }
        return text.withCString { cText in
            guard let raw = functions?.sanitize(cText) else { return nil }
            defer { functions?.freeString(raw) }
            return String(cString: raw)
        }
    }

    /// Must be called with lock already held.
    private func ensureLoadedUnlocked() -> Bool {
        if functions != nil { return true }
        if loadAttempted { return false }
        loadAttempted = true

        guard let loaded = RustDylib.load(label: "RustEscapeSanitizer", resolver: loadFunctions(from:)) else {
            return false
        }
        functions = loaded.functions
        return true
    }

    private func loadFunctions(from handle: UnsafeMutableRawPointer) -> Functions? {
        guard let sanitizeSym = dlsym(handle, "chau7_escape_sanitize"),
              let freeSym = dlsym(handle, "chau7_parse_string_free")
        else {
            return nil
        }
        let sanitize = unsafeBitCast(sanitizeSym, to: Sanitize.self)
        let freeString = unsafeBitCast(freeSym, to: FreeString.self)
        return Functions(sanitize: sanitize, freeString: freeString)
    }
}
