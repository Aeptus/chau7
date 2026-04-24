import Foundation
import Darwin

public final class RustPatternMatcher {
    public static let outputPatterns = RustPatternMatcher()
    public static let waitPatterns = RustPatternMatcher()

    private typealias PatternsCreate = @convention(c) (UnsafePointer<UnsafePointer<CChar>?>?, Int) -> UnsafeMutableRawPointer?
    private typealias PatternsFree = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias MatchFirst = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>) -> Int32
    private typealias MatchAny = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>) -> Bool

    private struct Functions {
        let create: PatternsCreate
        let free: PatternsFree
        let matchFirst: MatchFirst
        let matchAny: MatchAny
    }

    private let lock = NSLock()
    private var loadAttempted = false
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

    /// Returns the index of the first pattern that matches `haystack`, or
    /// `nil` for every "not found" outcome — empty pattern list, no match,
    /// FFI unavailable, or handle-allocation failure. Callers should not
    /// distinguish between these; there's nothing useful to do differently.
    ///
    /// Indices are guaranteed `>= 0`. The Rust side signals "no match" via
    /// `Int32(-1)`; this wrapper normalizes it to `nil` so Swift callers
    /// don't have to carry a secondary sentinel.
    public func firstMatchIndex(haystack: String, patterns: [String]) -> Int? {
        guard !patterns.isEmpty else { return nil }
        guard ensureLoaded() else { return nil }
        let hash = patternHash(for: patterns)
        lock.lock()
        defer { lock.unlock() }
        guard let handle = ensurePatternHandle(for: patterns, hash: hash) else { return nil }
        return haystack.withCString { cHaystack in
            let raw = Int(functions?.matchFirst(handle, cHaystack) ?? -1)
            return raw >= 0 ? raw : nil
        }
    }

    public func containsAny(haystack: String, patterns: [String]) -> Bool? {
        guard !patterns.isEmpty else { return false }
        guard ensureLoaded() else { return nil }
        let hash = patternHash(for: patterns)
        lock.lock()
        defer { lock.unlock() }
        guard let handle = ensurePatternHandle(for: patterns, hash: hash) else { return nil }
        return haystack.withCString { cHaystack in
            functions?.matchAny(handle, cHaystack) ?? false
        }
    }

    private func ensureLoaded() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if functions != nil { return true }
        if loadAttempted { return false }
        loadAttempted = true

        guard let loaded = RustDylib.load(label: "RustPatternMatcher", resolver: loadFunctions(from:)) else {
            return false
        }
        functions = loaded.functions
        return true
    }

    private func loadFunctions(from handle: UnsafeMutableRawPointer) -> Functions? {
        guard let createSym = dlsym(handle, "chau7_match_patterns_create"),
              let freeSym = dlsym(handle, "chau7_match_patterns_free"),
              let matchFirstSym = dlsym(handle, "chau7_match_first"),
              let matchAnySym = dlsym(handle, "chau7_match_any")
        else {
            return nil
        }
        let create = unsafeBitCast(createSym, to: PatternsCreate.self)
        let free = unsafeBitCast(freeSym, to: PatternsFree.self)
        let matchFirst = unsafeBitCast(matchFirstSym, to: MatchFirst.self)
        let matchAny = unsafeBitCast(matchAnySym, to: MatchAny.self)
        return Functions(create: create, free: free, matchFirst: matchFirst, matchAny: matchAny)
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
