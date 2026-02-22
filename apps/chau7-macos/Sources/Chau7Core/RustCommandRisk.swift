import Foundation
import Darwin

private func stderrPrint(_ message: String) {
    fputs(message + "\n", stderr)
}

final class RustCommandRisk {
    static let shared = RustCommandRisk()

    private typealias PatternsCreate = @convention(c) (UnsafePointer<UnsafePointer<CChar>?>?, Int) -> UnsafeMutableRawPointer?
    private typealias PatternsFree = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias IsRisky = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>) -> Bool

    private struct Functions {
        let create: PatternsCreate
        let free: PatternsFree
        let isRisky: IsRisky
    }

    private let lock = NSLock()
    private var loadAttempted = false
    private var dylibHandle: UnsafeMutableRawPointer?
    private var functions: Functions?
    private var patternHash: Int?
    private var patternsHandle: UnsafeMutableRawPointer?

    private init() {}

    deinit {
        lock.lock()
        defer { lock.unlock() }
        if let handle = patternsHandle {
            functions?.free(handle)
            patternsHandle = nil
        }
    }

    func isRisky(command: String, patterns: [String]) -> Bool? {
        guard !patterns.isEmpty else { return false }
        guard ensureLoaded() else { return nil }

        let hash = patternHash(for: patterns)
        lock.lock()
        defer { lock.unlock() }
        let handle = ensurePatternHandle(for: patterns, hash: hash)
        guard let handle else { return nil }
        return command.withCString { cCommand in
            functions?.isRisky(handle, cCommand) ?? false
        }
    }

    private func ensureLoaded() -> Bool {
        lock.lock()
        defer { lock.unlock() }
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
            stderrPrint("[RustCommandRisk] dlopen failed. Tried: \(candidates). Last error: \(lastError ?? "unknown")")
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
        guard let createSym = dlsym(handle, "chau7_risk_patterns_create"),
              let freeSym = dlsym(handle, "chau7_risk_patterns_free"),
              let riskySym = dlsym(handle, "chau7_risk_is_risky")
        else {
            return nil
        }
        let create = unsafeBitCast(createSym, to: PatternsCreate.self)
        let free = unsafeBitCast(freeSym, to: PatternsFree.self)
        let isRisky = unsafeBitCast(riskySym, to: IsRisky.self)
        return Functions(create: create, free: free, isRisky: isRisky)
    }

    private func ensurePatternHandle(for patterns: [String], hash: Int) -> UnsafeMutableRawPointer? {
        if let existing = patternsHandle, patternHash == hash {
            return existing
        }

        if let existing = patternsHandle {
            functions?.free(existing)
            patternsHandle = nil
        }

        var cStrings: [UnsafePointer<CChar>?] = []
        cStrings.reserveCapacity(patterns.count)
        for pattern in patterns {
            let dup = strdup(pattern)
            cStrings.append(dup)
        }
        defer {
            for ptr in cStrings {
                if let ptr {
                    free(UnsafeMutablePointer(mutating: ptr))
                }
            }
        }

        let newHandle = cStrings.withUnsafeBufferPointer { buffer -> UnsafeMutableRawPointer? in
            guard let base = buffer.baseAddress else { return nil }
            return functions?.create(base, patterns.count)
        }

        patternsHandle = newHandle
        patternHash = hash
        return newHandle
    }

    private func patternHash(for patterns: [String]) -> Int {
        var hasher = Hasher()
        for pattern in patterns {
            hasher.combine(pattern)
        }
        return hasher.finalize()
    }
}
