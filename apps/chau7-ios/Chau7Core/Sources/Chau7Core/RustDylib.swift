import Foundation
import Darwin

/// Shared scaffolding for the FFI wrappers that link against
/// `libchau7_parse.dylib`. Extracts the three duplicated pieces that
/// `RustCommandRisk`, `RustEscapeSanitizer`, and `RustPatternMatcher`
/// previously each carried independently:
///
///   1. The candidate-path search (env override → bundle resource →
///      bundle resource-root → bundle private-frameworks).
///   2. The dlopen-then-symbol-resolve sequence with stderr-logged
///      failure reporting.
///   3. The "one-shot attempt then latch" protocol — callers that fail
///      to load should not retry on every invocation.
///
/// Each caller still owns its own strongly-typed `Functions` bundle and
/// its `dlsym` closure; `RustDylib` only generalizes the common shell.
///
/// Logging goes through `stderr` (not `Chau7CoreLog`) because library
/// load can run at static-init time, before `AppDelegate` has wired the
/// Core log hooks.
enum RustDylib {
    /// Returns the candidate dylib paths in priority order:
    /// 1. `CHAU7_RUST_LIB_PATH` env override (used by tests and local
    ///    dev builds that don't bundle the dylib).
    /// 2. Bundled resource by name (`Bundle.main.path(forResource:ofType:)`).
    /// 3. Direct path under `Bundle.main.resourcePath`.
    /// 4. Direct path under `Bundle.main.privateFrameworksPath` (for
    ///    release builds where the dylib is embedded in Frameworks/).
    static func libraryCandidates() -> [String] {
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

    /// Loads the dylib from the first viable candidate path and resolves
    /// symbols through `resolver`. Returns `(handle, functions)` on
    /// success, `nil` when every candidate either failed to `dlopen` or
    /// succeeded but lacked one of the expected symbols.
    ///
    /// The `label` is used solely to tag stderr diagnostics (e.g.
    /// `"RustCommandRisk"`).
    ///
    /// The handle returned alongside `functions` is intentionally
    /// *not* `dlclose`d by this function. Callers typically store it in
    /// a singleton and let the OS reclaim the mapping at process exit;
    /// re-closing at runtime would invalidate every symbol pointer we
    /// just handed out.
    static func load<Functions>(
        label: String,
        resolver: (UnsafeMutableRawPointer) -> Functions?
    ) -> (handle: UnsafeMutableRawPointer, functions: Functions)? {
        let candidates = libraryCandidates()
        var lastError: String?
        for path in candidates {
            if let handle = dlopen(path, RTLD_NOW) {
                if let functions = resolver(handle) {
                    return (handle, functions)
                }
                dlclose(handle)
                lastError = "symbols not found in \(path)"
            } else {
                lastError = String(cString: dlerror())
            }
        }
        if !candidates.isEmpty, shouldLogLoadFailure() {
            stderrPrint("[\(label)] dlopen failed. Tried: \(candidates). Last error: \(lastError ?? "unknown")")
        }
        return nil
    }

    static func shouldLogLoadFailure(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        testClassIsLoaded: () -> Bool = {
            NSClassFromString("XCTestCase") != nil || NSClassFromString("XCTest.XCTestCase") != nil
        }
    ) -> Bool {
        if let override = boolOverride(environment["CHAU7_RUST_DYLIB_LOG_FAILURES"]) {
            return override
        }

        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil {
            return false
        }

        if environment["CI"] != nil || environment["GITHUB_ACTIONS"] != nil || environment["CODEX_CI"] != nil {
            return false
        }

        if testClassIsLoaded() {
            return false
        }

        return true
    }

    private static func boolOverride(_ raw: String?) -> Bool? {
        guard let normalized = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !normalized.isEmpty else {
            return nil
        }

        switch normalized {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    private static func stderrPrint(_ message: String) {
        fputs(message + "\n", stderr)
    }
}
