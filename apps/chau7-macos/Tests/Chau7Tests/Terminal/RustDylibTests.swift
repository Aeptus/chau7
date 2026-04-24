import XCTest
@testable import Chau7Core

/// `RustDylib` is a scaffolding helper for the three `libchau7_parse.dylib`
/// wrappers. These tests cover the one piece we can exercise without the
/// actual dylib: the candidate-path search. The `load(label:resolver:)`
/// dlopen path is covered indirectly through every existing test that
/// invokes `RustPatternMatcher` / `RustCommandRisk` / `RustEscapeSanitizer`
/// (all three now route their load through `RustDylib.load`).
final class RustDylibTests: XCTestCase {
    func testLibraryCandidates_includesBundleLocations() {
        let candidates = RustDylib.libraryCandidates()

        // In isolation (`swift test`) there's no main-bundle resource for
        // the dylib, but the resource-root and frameworks paths are always
        // emitted based on `Bundle.main` properties. The list must be
        // non-empty and every path must end in `libchau7_parse.dylib` (so
        // a typo in the filename would be caught here).
        XCTAssertFalse(candidates.isEmpty, "bundle candidate paths should always contribute at least one entry")
        for path in candidates {
            XCTAssertTrue(
                path.hasSuffix("libchau7_parse.dylib") || path == ProcessInfo.processInfo.environment["CHAU7_RUST_LIB_PATH"],
                "unexpected candidate: \(path)"
            )
        }
    }

    func testLibraryCandidates_prioritizesEnvOverride() {
        let key = "CHAU7_RUST_LIB_PATH"
        let originalValue = ProcessInfo.processInfo.environment[key]
        setenv(key, "/tmp/override/libchau7_parse.dylib", 1)
        defer {
            if let originalValue {
                setenv(key, originalValue, 1)
            } else {
                unsetenv(key)
            }
        }

        let candidates = RustDylib.libraryCandidates()

        XCTAssertEqual(
            candidates.first,
            "/tmp/override/libchau7_parse.dylib",
            "env override must appear first so tests and local dev builds bypass bundle lookup"
        )
    }

    func testLoad_returnsNilWhenNoCandidatesResolve() {
        // Point the override at a nonexistent path; no bundle resource
        // exists in the test harness, so every candidate should fail.
        let key = "CHAU7_RUST_LIB_PATH"
        let originalValue = ProcessInfo.processInfo.environment[key]
        setenv(key, "/nonexistent/definitely/no/libchau7_parse.dylib", 1)
        defer {
            if let originalValue {
                setenv(key, originalValue, 1)
            } else {
                unsetenv(key)
            }
        }

        struct DummyFunctions {}
        let result = RustDylib.load(label: "RustDylibTests") { _ -> DummyFunctions? in
            XCTFail("resolver must not run when every dlopen fails")
            return nil
        }

        XCTAssertNil(result, "load must return nil when no candidate dlopens successfully")
    }
}
