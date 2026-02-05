import Foundation
import Darwin

struct RustAnsiColorSpec {
    var kind: UInt8
    var index: UInt8
    var r: UInt8
    var g: UInt8
    var b: UInt8
}

struct RustAnsiSegment {
    var text: UnsafeMutablePointer<CChar>?
    var flags: UInt32
    var fg: RustAnsiColorSpec
    var bg: RustAnsiColorSpec
}

struct RustAnsiSegments {
    var segments: UnsafeMutablePointer<RustAnsiSegment>?
    var count: Int
}

struct RustAnsiParsedSegment {
    let text: String
    let flags: UInt32
    let fg: RustAnsiColorSpec
    let bg: RustAnsiColorSpec
}

final class RustAnsiParser {
    static let shared = RustAnsiParser()

    private typealias Parse = @convention(c) (UnsafePointer<CChar>) -> UnsafeMutableRawPointer?
    private typealias FreeSegments = @convention(c) (UnsafeMutableRawPointer?) -> Void

    private struct Functions {
        let parse: Parse
        let freeSegments: FreeSegments
    }

    private let lock = NSLock()
    private var loadAttempted = false
    private var dylibHandle: UnsafeMutableRawPointer?
    private var functions: Functions?

    private init() {}

    func parse(_ text: String) -> [RustAnsiParsedSegment]? {
        guard ensureLoaded() else { return nil }
        return text.withCString { cText in
            guard let raw = functions?.parse(cText) else { return nil }
            defer { functions?.freeSegments(raw) }
            let wrapper = raw.assumingMemoryBound(to: RustAnsiSegments.self)
            let count = wrapper.pointee.count
            guard count > 0, let base = wrapper.pointee.segments else { return [] }
            let buffer = UnsafeBufferPointer(start: base, count: count)
            var parsed: [RustAnsiParsedSegment] = []
            parsed.reserveCapacity(count)
            for seg in buffer {
                let text = seg.text.map { String(cString: $0) } ?? ""
                parsed.append(RustAnsiParsedSegment(text: text, flags: seg.flags, fg: seg.fg, bg: seg.bg))
            }
            return parsed
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
        guard let parseSym = dlsym(handle, "chau7_ansi_parse"),
              let freeSym = dlsym(handle, "chau7_ansi_segments_free")
        else {
            return nil
        }
        let parse = unsafeBitCast(parseSym, to: Parse.self)
        let freeSegments = unsafeBitCast(freeSym, to: FreeSegments.self)
        return Functions(parse: parse, freeSegments: freeSegments)
    }
}
