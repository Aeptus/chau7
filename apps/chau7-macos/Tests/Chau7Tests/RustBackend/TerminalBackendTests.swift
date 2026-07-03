import XCTest
@testable import Chau7

/// Verifies the `TerminalBackend` seam: the concrete `RustTerminalFFI` conforms
/// (checked at compile time without touching the dylib), and a lightweight
/// in-memory double can stand in for it. The whole point of the abstraction is
/// that a fake satisfies every requirement the view consumes, so drain/render
/// logic can be exercised without a real PTY.
final class TerminalBackendTests: XCTestCase {
    /// Compile-time conformance check: `RustTerminalFFI` is a `TerminalBackend`.
    /// Uses the metatype so nothing is instantiated (the real backend needs the
    /// Rust dylib and a live PTY, which unit tests must not spawn).
    func testRustTerminalFFIConformsToTerminalBackend() {
        let backendType: any TerminalBackend.Type = RustTerminalFFI.self
        XCTAssertTrue(backendType is RustTerminalFFI.Type)
    }

    /// A fake conforming to the protocol can be used through the abstraction,
    /// and observed calls are recorded — proving the seam is satisfiable by a
    /// test double.
    func testFakeBackendStandsInForTheProtocol() {
        let fake = FakeTerminalBackend()
        let backend: any TerminalBackend = fake

        backend.sendText("hello")
        backend.sendBytes([0x1B, 0x5B, 0x41])
        _ = backend.resize(cols: 80, rows: 24)
        let flags = backend.pollEvents(timeout: 0)

        XCTAssertEqual(fake.sentText, ["hello"])
        XCTAssertEqual(fake.sentBytes, [[0x1B, 0x5B, 0x41]])
        XCTAssertEqual(fake.lastResize?.cols, 80)
        XCTAssertEqual(fake.lastResize?.rows, 24)
        XCTAssertTrue(flags.isEmpty)
        XCTAssertEqual(backend.cursorPosition.col, 0)
        XCTAssertNil(backend.getSelectionText())
    }
}

/// Minimal in-memory `TerminalBackend` double. Records the mutating calls a
/// test might assert on and returns inert defaults for everything else. It
/// never allocates FFI/unsafe resources, so it is safe to use freely.
private final class FakeTerminalBackend: TerminalBackend {
    private(set) var sentText: [String] = []
    private(set) var sentBytes: [[UInt8]] = []
    private(set) var lastResize: (cols: UInt16, rows: UInt16)?

    // MARK: PTY Input

    func sendBytes(_ data: Data) {
        sentBytes.append([UInt8](data))
    }

    func sendBytes(_ bytes: [UInt8]) {
        sentBytes.append(bytes)
    }

    func sendText(_ text: String) {
        sentText.append(text)
    }

    func injectOutput(_ data: Data) {
        sentBytes.append([UInt8](data))
    }

    // MARK: Sizing

    func resize(cols: UInt16, rows: UInt16) {
        lastResize = (cols, rows)
    }

    func nudgeWinsize() {}

    // MARK: Grid / Rows

    func getGrid() -> (snapshot: UnsafeMutablePointer<RustGridSnapshot>, free: () -> Void)? {
        nil
    }

    func getLineText(row: Int) -> String? {
        nil
    }

    func getLogicalLineHit(row: Int, column: Int) -> RustTerminalFFI.LogicalLineHit? {
        nil
    }

    var cursorPosition: (col: UInt16, row: UInt16) {
        (0, 0)
    }

    // MARK: Selection

    func getSelectionText() -> String? {
        nil
    }

    func clearSelection() {}
    func startSelection(col: Int32, row: Int32, selectionType: UInt8) {}
    func updateSelection(col: Int32, row: Int32) {}
    func selectAll() {}

    // MARK: Scrolling

    var scrollPosition: Double {
        0
    }

    func scrollTo(position: Double) {}
    func scrollLines(_ lines: Int32) {}
    var displayOffset: UInt32 {
        0
    }

    // MARK: Polling

    func pollEvents(timeout: UInt32) -> TerminalPollEventFlags {
        TerminalPollEventFlags()
    }

    // MARK: Theming

    func setColors(
        fg: (UInt8, UInt8, UInt8),
        bg: (UInt8, UInt8, UInt8),
        cursor: (UInt8, UInt8, UInt8),
        palette: [(UInt8, UInt8, UInt8)]
    ) {}

    // MARK: Scrollback / Output

    func clearScrollback() {}
    func getLastOutput() -> Data? {
        nil
    }

    // MARK: Modes

    func isBracketedPasteMode() -> Bool {
        false
    }

    func checkBell() -> Bool {
        false
    }

    func mouseMode() -> UInt32 {
        0
    }

    func isAlternateScreenActive() -> Bool {
        false
    }

    func isApplicationCursorMode() -> Bool {
        false
    }

    // MARK: Process

    func shellPid() -> pid_t {
        0
    }

    func isPtyClosed() -> Bool {
        false
    }

    func isEchoDisabledViaTermios() -> Bool? {
        nil
    }

    // MARK: Buffer Capture

    func tailBufferAnsiText(maxLines: Int, maxBytes: Int) -> String? {
        nil
    }

    func fullBufferText() -> String? {
        nil
    }

    func fullBufferAnsiText() -> String? {
        nil
    }

    // MARK: Pending Terminal Events

    func getPendingTitle() -> String? {
        nil
    }

    func getPendingCwd() -> String? {
        nil
    }

    func getPendingExitCode() -> Int32? {
        nil
    }

    func getPendingShellIntegrationEvents() -> [ShellIntegrationEvent] {
        []
    }

    // MARK: Hyperlinks (OSC 8)

    func getLinkUrl(linkId: UInt16) -> String? {
        nil
    }

    // MARK: Clipboard (OSC 52)

    func getPendingClipboard() -> String? {
        nil
    }

    func hasClipboardRequest() -> Bool {
        false
    }

    func respondClipboard(text: String) {}

    // MARK: Graphics Protocols

    func getPendingImages() -> [(protocol: UInt8, data: Data, anchorRow: Int32, anchorCol: UInt16)]? {
        nil
    }

    func setImageProtocols(sixel: Bool, kitty: Bool, iterm2: Bool) {}

    // MARK: ScrollbackMemoryRustFFI (inherited)

    func setScrollbackSize(_ lines: UInt32) {}
    func captureFullBufferText() -> String? {
        nil
    }

    func captureFullBufferAnsiText() -> String? {
        nil
    }

    func replayBuffer(_ data: Data) {}
}
