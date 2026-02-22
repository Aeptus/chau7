import Foundation
import Darwin

private func stderrPrint(_ message: String) {
    fputs(message + "\n", stderr)
}

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
    private var dylibHandle: UnsafeMutableRawPointer?
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

        let candidates = libraryCandidates()
        var lastError: String?
        for path in candidates {
            if let handle = dlopen(path, RTLD_NOW) {
                dylibHandle = handle
                if let f = loadFunctions(from: handle) {
                    functions = f
                    return true
                } else {
                    dlclose(handle)
                    dylibHandle = nil
                    lastError = "symbols not found in \(path)"
                }
            } else {
                lastError = String(cString: dlerror())
            }
        }
        if !candidates.isEmpty {
            stderrPrint("[RustEscapeSanitizer] dlopen failed. Tried: \(candidates). Last error: \(lastError ?? "unknown")")
        }
        return false
    }

    private func libraryCandidates() -> [String] {
        var paths: [String] = []
        if let envPath = ProcessInfo.processInfo.environment["CHAU7_RUST_LIB_PATH"], !envPath.isEmpty {
            paths.append(envPath)
        }
        if let resourcePath = Bundle.main.path(forResource: "libchau7_parse", ofType: "dylib") {
            paths.append(resourcePath)
        }
        if let resourceRoot = Bundle.main.resourcePath {
            paths.append("\(resourceRoot)/libchau7_parse.dylib")
        }
        if let frameworksRoot = Bundle.main.privateFrameworksPath {
            paths.append("\(frameworksRoot)/libchau7_parse.dylib")
        }
        return paths
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
