import Foundation
import Darwin

final class RustDimPatcher {
    static let shared = RustDimPatcher()

    private struct PatchedBuffer {
        var data: UnsafeMutablePointer<UInt8>?
        var len: Int
        var capacity: Int
        var changed: Bool
    }

    private typealias PatchDim = @convention(c) (UnsafePointer<UInt8>?, Int) -> UnsafeMutableRawPointer?
    private typealias PatchDimFree = @convention(c) (UnsafeMutableRawPointer?) -> Void

    private struct Functions {
        let patchDim: PatchDim
        let patchDimFree: PatchDimFree
    }

    private let lock = NSLock()
    private var loadAttempted = false
    private var dylibHandle: UnsafeMutableRawPointer?
    private var functions: Functions?

    private init() {}

    deinit {
        if let handle = dylibHandle {
            dlclose(handle)
        }
    }

    /// Patches dim sequences in the given byte slice.
    /// Returns the patched bytes if changes were made, or nil if no dim sequences found
    /// (caller should use original data).
    func patchDim(_ slice: ArraySlice<UInt8>) -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        guard ensureLoadedUnlocked() else { return nil }

        return slice.withUnsafeBufferPointer { buffer -> [UInt8]? in
            guard let baseAddress = buffer.baseAddress else { return nil }
            guard let raw = functions?.patchDim(baseAddress, buffer.count) else { return nil }
            defer { functions?.patchDimFree(raw) }

            let result = raw.assumingMemoryBound(to: PatchedBuffer.self)
            guard result.pointee.changed, let data = result.pointee.data else {
                return nil // No changes needed — caller uses original
            }

            let len = result.pointee.len
            return Array(UnsafeBufferPointer(start: data, count: len))
        }
    }

    /// Must be called with lock already held.
    private func ensureLoadedUnlocked() -> Bool {
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
        guard let patchSym = dlsym(handle, "chau7_patch_dim"),
              let freeSym = dlsym(handle, "chau7_patch_dim_free")
        else {
            return nil
        }
        let patchDim = unsafeBitCast(patchSym, to: PatchDim.self)
        let patchDimFree = unsafeBitCast(freeSym, to: PatchDimFree.self)
        return Functions(patchDim: patchDim, patchDimFree: patchDimFree)
    }
}
