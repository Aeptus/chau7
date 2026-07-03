import Foundation

/// Abstraction over the terminal engine that `RustTerminalView` drives.
///
/// The view and its extensions historically reached straight into the concrete
/// `RustTerminalFFI` class. This protocol captures exactly the instance-method
/// and property surface those call sites consume, so the view depends on a
/// seam rather than the FFI implementation. That makes the drain/render/input
/// logic testable with a lightweight double and keeps the dlopen/symbol-binding
/// concrete type an implementation detail.
///
/// Scope notes:
/// - Statics (`RustTerminalFFI.isAvailable`), initializers, and nested value
///   types (`FFIImageData`, `FFIImageArray`, `DebugState`) are deliberately
///   NOT requirements — they are concrete construction/layout details, not
///   dispatched behavior. Construction sites keep naming `RustTerminalFFI`.
/// - `LogicalLineHit` is referenced as a plain data carrier returned by
///   `getLogicalLineHit`; it stays nested on the concrete type.
/// - Refines `ScrollbackMemoryRustFFI` because the view forwards the backend to
///   `ScrollbackMemoryManager` (which types its input as that protocol). This
///   inherits `setScrollbackSize`, `replayBuffer`, `captureFullBufferText`, and
///   `captureFullBufferAnsiText` without redeclaring them.
protocol TerminalBackend: ScrollbackMemoryRustFFI {

    // MARK: - PTY Input

    func sendBytes(_ data: Data)
    func sendBytes(_ bytes: [UInt8])
    func sendText(_ text: String)
    func injectOutput(_ data: Data)

    // MARK: - Sizing

    func resize(cols: UInt16, rows: UInt16)
    func nudgeWinsize()

    // MARK: - Grid / Rows

    func getGrid() -> (snapshot: UnsafeMutablePointer<RustGridSnapshot>, free: () -> Void)?
    func getLineText(row: Int) -> String?
    func getLogicalLineHit(row: Int, column: Int) -> RustTerminalFFI.LogicalLineHit?
    var cursorPosition: (col: UInt16, row: UInt16) { get }

    // MARK: - Selection

    func getSelectionText() -> String?
    func clearSelection()
    func startSelection(col: Int32, row: Int32, selectionType: UInt8)
    func updateSelection(col: Int32, row: Int32)
    func selectAll()

    // MARK: - Scrolling

    var scrollPosition: Double { get }
    func scrollTo(position: Double)
    func scrollLines(_ lines: Int32)
    var displayOffset: UInt32 { get }

    // MARK: - Polling

    func pollEvents(timeout: UInt32) -> TerminalPollEventFlags

    // MARK: - Theming

    func setColors(
        fg: (UInt8, UInt8, UInt8),
        bg: (UInt8, UInt8, UInt8),
        cursor: (UInt8, UInt8, UInt8),
        palette: [(UInt8, UInt8, UInt8)]
    )

    // MARK: - Scrollback / Output

    func clearScrollback()
    func getLastOutput() -> Data?

    // MARK: - Modes

    func isBracketedPasteMode() -> Bool
    func checkBell() -> Bool
    func mouseMode() -> UInt32
    func isAlternateScreenActive() -> Bool
    func isApplicationCursorMode() -> Bool

    // MARK: - Process

    func shellPid() -> pid_t
    func isPtyClosed() -> Bool
    func isEchoDisabledViaTermios() -> Bool?

    // MARK: - Buffer Capture

    func tailBufferAnsiText(maxLines: Int, maxBytes: Int) -> String?
    func fullBufferText() -> String?
    func fullBufferAnsiText() -> String?

    // MARK: - Pending Terminal Events

    func getPendingTitle() -> String?
    func getPendingCwd() -> String?
    func getPendingExitCode() -> Int32?
    func getPendingShellIntegrationEvents() -> [ShellIntegrationEvent]

    // MARK: - Hyperlinks (OSC 8)

    func getLinkUrl(linkId: UInt16) -> String?

    // MARK: - Clipboard (OSC 52)

    func getPendingClipboard() -> String?
    func hasClipboardRequest() -> Bool
    func respondClipboard(text: String)

    // MARK: - Graphics Protocols

    func getPendingImages() -> [(protocol: UInt8, data: Data, anchorRow: Int32, anchorCol: UInt16)]?
    func setImageProtocols(sixel: Bool, kitty: Bool, iterm2: Bool)
}
