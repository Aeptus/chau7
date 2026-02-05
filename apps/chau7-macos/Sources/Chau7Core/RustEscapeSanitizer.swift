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
    private var dylibHandle: UnsafeMutableRawPointer?
    private var functions: Functions?

    private init() {}

    func sanitize(_ text: String) -> String? {
        guard ensureLoaded() else { return nil }
        return text.withCString { cText in
            guard let raw = functions?.sanitize(cText) else { return nil }
            defer { functions?.freeString(raw) }
            return String(cString: raw)
        }
    }

    private func ensureLoaded() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if functions != nil { return true }
        if loadAttempted { return false }
        loadAttempted = true

        let candidates = libraryCandidates()
        for path in candidates {
            if let handle = dlopen(path, RTLD_NOW) {
                dylibHandle = handle
                if let f = loadFunctions(from: handle) {
                    functions = f
                    return true
                } else {
                    dlclose(handle)
                    dylibHandle = nil
                }
            }
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
              let freeSym = dlsym(handle, "chau7_escape_string_free")
        else {
            return nil
        }
        let sanitize = unsafeBitCast(sanitizeSym, to: Sanitize.self)
        let freeString = unsafeBitCast(freeSym, to: FreeString.self)
        return Functions(sanitize: sanitize, freeString: freeString)
    }
}
