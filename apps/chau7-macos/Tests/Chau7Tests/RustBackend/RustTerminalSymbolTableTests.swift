import Darwin
import XCTest
@testable import Chau7

/// Loader-behavior tests for `RustTerminalSymbolTable` that don't require the
/// real Rust dylib: nonexistent paths, stub dylibs compiled on the fly with
/// `clang -dynamiclib` (missing ABI probe, wrong ABI version, layout mismatch,
/// required-symbols-only), and the pure version/layout decision helpers.
///
/// The full contract against the actually-built `libchau7_terminal.dylib`
/// lives in `RustDylibIntegrationTests`.
final class RustTerminalSymbolTableTests: XCTestCase {

    // MARK: - Pure decision helpers

    func testABIVersionDecision() {
        // No probe symbol (pre-probe build): load without verification.
        XCTAssertTrue(RustTerminalSymbolTable.isABIVersionCompatible(nil))
        // Matching version: accept.
        XCTAssertTrue(RustTerminalSymbolTable.isABIVersionCompatible(RustTerminalSymbolTable.expectedABIVersion))
        // Any other version: refuse to bind.
        XCTAssertFalse(RustTerminalSymbolTable.isABIVersionCompatible(RustTerminalSymbolTable.expectedABIVersion + 1))
        XCTAssertFalse(RustTerminalSymbolTable.isABIVersionCompatible(0, expected: 1))
    }

    func testLayoutDecision() {
        // Probe symbol absent: skip (older dylib without that probe).
        XCTAssertTrue(RustTerminalSymbolTable.isLayoutCompatible(probedSize: nil, swiftStride: 20))
        // Matching stride: accept.
        XCTAssertTrue(RustTerminalSymbolTable.isLayoutCompatible(probedSize: 20, swiftStride: 20))
        // Any drift: refuse to bind.
        XCTAssertFalse(RustTerminalSymbolTable.isLayoutCompatible(probedSize: 24, swiftStride: 20))
    }

    // MARK: - Loader behavior

    func testLoadReturnsNilForNonexistentPath() {
        let result = RustTerminalSymbolTable.load(path: "/nonexistent/definitely-not-here/libchau7_terminal.dylib")
        XCTAssertNil(result)
    }

    func testLoadReturnsNilForPreProbeDylibMissingRequiredSymbols() throws {
        // A dylib with no ABI version probe takes the pre-probe fallback
        // (verification skipped), then fails binding on required symbols.
        let dylib = try compileStubDylib(
            source: "int chau7_stub_unrelated(void) { return 0; }\n",
            named: "preprobe-empty"
        )

        let logLines = captureLogs {
            XCTAssertNil(RustTerminalSymbolTable.load(path: dylib))
        }
        XCTAssertTrue(
            logLines.contains { $0.contains("no ABI version probe (pre-probe build)") },
            "pre-probe fallback should be taken before binding:\n\(logLines.joined(separator: "\n"))"
        )
        XCTAssertTrue(
            logLines.contains { $0.contains("One or more required symbols missing") },
            "binding should refuse on missing required symbols:\n\(logLines.joined(separator: "\n"))"
        )
    }

    func testLoadRefusesToBindOnABIVersionMismatch() throws {
        let dylib = try compileStubDylib(
            source: "unsigned int chau7_terminal_abi_version(void) { return 999; }\n",
            named: "wrong-abi-version"
        )

        let logLines = captureLogs {
            XCTAssertNil(RustTerminalSymbolTable.load(path: dylib))
        }
        XCTAssertTrue(
            logLines.contains { $0.contains("ABI version mismatch") && $0.contains("refusing to bind") },
            "version mismatch must refuse to bind:\n\(logLines.joined(separator: "\n"))"
        )
    }

    func testLoadRefusesToBindOnLayoutProbeMismatch() throws {
        let dylib = try compileStubDylib(
            source: """
            unsigned int chau7_terminal_abi_version(void) { return \(RustTerminalSymbolTable.expectedABIVersion); }
            unsigned long chau7_terminal_sizeof_cell_data(void) { return 1; }
            """,
            named: "layout-mismatch"
        )

        let logLines = captureLogs {
            XCTAssertNil(RustTerminalSymbolTable.load(path: dylib))
        }
        XCTAssertTrue(
            logLines.contains { $0.contains("layout mismatch for CellData") && $0.contains("refusing to bind") },
            "layout drift must refuse to bind:\n\(logLines.joined(separator: "\n"))"
        )
    }

    func testLoadBindsRequiredSymbolsAndLeavesMissingOptionalsNil() throws {
        // Only the 15 required symbols (plus a matching ABI version). Every
        // optional symbol must come back nil — the graceful
        // "symbol missing → feature disabled" fallback contract.
        let requiredSymbols = [
            "chau7_terminal_create",
            "chau7_terminal_destroy",
            "chau7_terminal_send_bytes",
            "chau7_terminal_send_text",
            "chau7_terminal_resize",
            "chau7_terminal_get_grid",
            "chau7_terminal_free_grid",
            "chau7_terminal_scroll_position",
            "chau7_terminal_scroll_to",
            "chau7_terminal_scroll_lines",
            "chau7_terminal_selection_text",
            "chau7_terminal_selection_clear",
            "chau7_terminal_free_string",
            "chau7_terminal_cursor_position",
            "chau7_terminal_poll"
        ]
        // dlsym only resolves names; the stubs are never invoked by this test.
        let stubs = requiredSymbols.map { "void \($0)(void) {}" }.joined(separator: "\n")
        let dylib = try compileStubDylib(
            source: """
            unsigned int chau7_terminal_abi_version(void) { return \(RustTerminalSymbolTable.expectedABIVersion); }
            \(stubs)
            """,
            named: "required-only"
        )

        var loaded: RustTerminalSymbolTable.LoadedLibrary?
        let logLines = captureLogs {
            loaded = RustTerminalSymbolTable.load(path: dylib)
        }
        let library = try XCTUnwrap(loaded, "required-only dylib should bind:\n\(logLines.joined(separator: "\n"))")
        let table = library.symbols

        XCTAssertTrue(
            logLines.contains { $0.contains("ABI contract verified") },
            "layout probes are absent, so verification should skip them and pass:\n\(logLines.joined(separator: "\n"))"
        )
        XCTAssertTrue(
            logLines.contains { $0.contains("All 15 required symbols loaded successfully") },
            "expected the required-symbols success log:\n\(logLines.joined(separator: "\n"))"
        )

        // Every optional binding stays nil when the symbol is absent.
        XCTAssertNil(table.createWithEnv)
        XCTAssertNil(table.createWithLaunch)
        XCTAssertNil(table.nudgeWinsize)
        XCTAssertNil(table.selectionStart)
        XCTAssertNil(table.selectionUpdate)
        XCTAssertNil(table.selectionAll)
        XCTAssertNil(table.pollEvents)
        XCTAssertNil(table.setColors)
        XCTAssertNil(table.clearScrollback)
        XCTAssertNil(table.getLastOutput)
        XCTAssertNil(table.freeOutput)
        XCTAssertNil(table.injectOutput)
        XCTAssertNil(table.setScrollbackSize)
        XCTAssertNil(table.replayBuffer)
        XCTAssertNil(table.displayOffset)
        XCTAssertNil(table.isBracketedPasteMode)
        XCTAssertNil(table.isAlternateScreenActive)
        XCTAssertNil(table.checkBell)
        XCTAssertNil(table.getMouseMode)
        XCTAssertNil(table.isMouseReportingActive)
        XCTAssertNil(table.isApplicationCursorMode)
        XCTAssertNil(table.getShellPid)
        XCTAssertNil(table.getDebugState)
        XCTAssertNil(table.freeDebugState)
        XCTAssertNil(table.getFullBufferText)
        XCTAssertNil(table.getFullBufferAnsiText)
        XCTAssertNil(table.getTailBufferAnsiText)
        XCTAssertNil(table.resetMetrics)
        XCTAssertNil(table.getPendingTitle)
        XCTAssertNil(table.getPendingCwd)
        XCTAssertNil(table.getPendingExitCode)
        XCTAssertNil(table.isPtyClosed)
        XCTAssertNil(table.isEchoDisabled)
        XCTAssertNil(table.getLineTextDirect)
        XCTAssertNil(table.getLogicalLineTextDirect)
        XCTAssertNil(table.getLinkUrl)
        XCTAssertNil(table.getPendingClipboard)
        XCTAssertNil(table.hasClipboardRequest)
        XCTAssertNil(table.respondClipboard)
        XCTAssertNil(table.getPendingShellIntegrationEvents)
        XCTAssertNil(table.freeShellIntegrationEvents)
        XCTAssertNil(table.getPendingImages)
        XCTAssertNil(table.freeImages)
        XCTAssertNil(table.setImageProtocols)
        XCTAssertNil(table.hasPendingImages)

        // The handle stays open on success (closing it would invalidate the
        // bound pointers); release it here since this table is test-local.
        _ = dlclose(library.handle)
    }

    // MARK: - Helpers

    /// Captures Log output for the duration of `body`. Trace lines may be
    /// absent (trace is env-gated); assertions must rely on info/warn/error.
    private func captureLogs(_ body: () -> Void) -> [String] {
        var lines: [String] = []
        let lock = NSLock()
        Log.sink = { line in
            lock.lock()
            lines.append(line)
            lock.unlock()
        }
        defer { Log.sink = nil }
        body()
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    /// Compiles a tiny stub dylib from C source into a per-test temp dir.
    /// Skips the test when clang is unavailable rather than failing.
    private func compileStubDylib(source: String, named name: String) throws -> String {
        let clangPath = "/usr/bin/clang"
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: clangPath),
            "clang unavailable; cannot compile stub dylib"
        )

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RustTerminalSymbolTableTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
        }

        let sourceURL = dir.appendingPathComponent("\(name).c")
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)
        let dylibURL = dir.appendingPathComponent("lib\(name).dylib")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: clangPath)
        process.arguments = ["-dynamiclib", "-o", dylibURL.path, sourceURL.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let diagnostics = String(decoding: errorData, as: UTF8.self)
            throw XCTSkip("clang failed to compile stub dylib (status \(process.terminationStatus)): \(diagnostics)")
        }
        return dylibURL.path
    }
}
