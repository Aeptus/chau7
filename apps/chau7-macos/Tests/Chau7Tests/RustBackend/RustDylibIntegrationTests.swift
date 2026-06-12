import XCTest
@testable import Chau7

/// End-to-end contract test against the actually-built dylib: dlopen, ABI
/// version handshake, struct-layout probes, symbol binding, PTY spawn with
/// argv, and an output round-trip. This is the test that catches Swift/Rust
/// drift — the classic version-skew failure mode for a dlopen FFI whose
/// struct layouts are hand-mirrored.
///
/// Skips when the dylib hasn't been built (run `just rust-build` first).
final class RustDylibIntegrationTests: XCTestCase {
    private static var dylibPath: String {
        // Tests/Chau7Tests/RustBackend/<this file> → package root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Libraries/libchau7_terminal.dylib")
            .path
    }

    func testCreateFeedAndDrainAgainstBuiltDylib() throws {
        let path = Self.dylibPath
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: path),
            "libchau7_terminal.dylib not built; run Scripts/build-rust.sh"
        )

        setenv("CHAU7_RUST_LIB_PATH", path, 1)
        defer { unsetenv("CHAU7_RUST_LIB_PATH") }
        RustTerminalFFI.resetLoadStateForTesting()

        // Capture load diagnostics so a failure explains itself.
        var logLines: [String] = []
        Log.sink = { logLines.append($0) }
        defer { Log.sink = nil }

        // Load + ABI handshake + layout probes happen here.
        XCTAssertTrue(
            RustTerminalFFI.isAvailable,
            "dylib failed to load or ABI contract verification failed:\n\(logLines.joined(separator: "\n"))"
        )

        // Full launch path: env + argv + cwd through chau7_terminal_create_with_launch.
        let terminal = try XCTUnwrap(
            RustTerminalFFI(
                cols: 80,
                rows: 24,
                shell: "/bin/sh",
                environment: ["CHAU7_FFI_TEST": "1"],
                args: ["-c", "echo CHAU7_FFI_ROUNDTRIP_OK; sleep 2"],
                workingDirectory: "/private/tmp"
            ),
            "terminal creation failed against the built dylib"
        )

        var combined = ""
        for _ in 0 ..< 100 {
            _ = terminal.poll(timeout: 50)
            if let data = terminal.getLastOutput(), !data.isEmpty {
                combined += String(decoding: data, as: UTF8.self)
            }
            if combined.contains("CHAU7_FFI_ROUNDTRIP_OK") { break }
        }
        XCTAssertTrue(
            combined.contains("CHAU7_FFI_ROUNDTRIP_OK"),
            "PTY output round-trip failed; received \(combined.count) bytes"
        )

        // Grid snapshot path: validates the hand-mirrored RustGridSnapshot /
        // RustCellData layouts against real Rust-allocated memory.
        let grid = try XCTUnwrap(terminal.getGrid(), "grid snapshot unavailable")
        defer { grid.free() }
        XCTAssertEqual(grid.snapshot.pointee.cols, 80)
        XCTAssertEqual(grid.snapshot.pointee.rows, 24)
        XCTAssertNotNil(grid.snapshot.pointee.cells)
    }
}
