import AppKit
import Chau7Core

// MARK: - Unified Terminal View Protocol

/// Protocol that defines the common interface for terminal views.
/// RustTerminalView conforms to this protocol, enabling backend-agnostic code
/// in the session model and UI layers.
///
/// This protocol is the single source of truth for terminal view capabilities.
protocol TerminalViewLike: NSView {

    // MARK: - Callbacks

    /// Called when PTY output is received
    var onOutput: ((Data) -> Void)? { get set }

    /// Called when user input is sent
    var onInput: ((String) -> Void)? { get set }

    /// Called before user-originated text is sent to the PTY.
    /// Return false to suppress the input.
    var shouldAcceptUserText: ((String) -> Bool)? { get set }

    /// Called when buffer content changes
    var onBufferChanged: (() -> Void)? { get set }

    /// Called when scroll position changes
    var onScrollChanged: (() -> Void)? { get set }

    /// Called when scrollback is cleared
    var onScrollbackCleared: (() -> Void)? { get set }

    /// Called for file path clicks (path, line, column)
    var onFilePathClicked: ((String, Int?, Int?) -> Void)? { get set }

    // MARK: - State Properties

    /// Current working directory for path resolution
    var currentDirectory: String { get set }

    /// Tab identifier for per-tab command history
    var tabIdentifier: String { get set }

    /// Closure to check if shell is at prompt (for history navigation)
    var isAtPrompt: (() -> Bool)? { get set }

    /// Whether to allow mouse reporting to the terminal
    var allowMouseReporting: Bool { get set }

    // MARK: - Read-Only Properties

    /// The font used for terminal rendering
    var font: NSFont { get }

    /// Whether the terminal view currently has keyboard focus
    var hasFocus: Bool { get }

    /// Frame of the cursor caret in view coordinates
    var caretFrame: CGRect { get }

    /// Whether there is currently selected text
    var hasSelection: Bool { get }

    /// Current scroll position (0.0 = bottom, 1.0 = top of history)
    var scrollPosition: Double { get }

    // MARK: - Backend-Native Data Access

    /// Number of visible rows in the terminal viewport.
    var terminalRows: Int { get }

    /// Number of columns in the terminal viewport.
    var terminalCols: Int { get }

    /// Current cursor row in absolute buffer coordinates (accounting for scrollback).
    /// This is the row index counting from the top of history (row 0 = first history line).
    var currentAbsoluteRow: Int { get }

    /// Returns the full terminal buffer (screen + scrollback) as UTF-8 Data.
    /// Each line is newline-terminated. Trailing spaces on each line are trimmed.
    func getBufferAsData() -> Data?

    /// Returns a structured visible-grid snapshot for high-fidelity remote rendering.
    /// Implementations may return nil when no structured snapshot is available.
    func captureRemoteGridSnapshotPayload() -> Data?

    /// Get the text content of a specific row in absolute buffer coordinates.
    /// Row 0 is the first line in scrollback history.
    /// Returns empty string if the row is out of range.
    func getLineText(absoluteRow: Int) -> String

    // MARK: - Input Methods

    /// Send raw bytes to the PTY
    func send(data bytes: [UInt8])

    /// Send text to the PTY
    func send(txt text: String)

    /// Send a normalized key press to the PTY
    func send(keyPress: TerminalKeyPress)

    /// Paste text into the terminal, using bracketed paste when supported.
    func pasteText(_ text: String)

    // MARK: - Selection Methods

    /// Get selected text
    func getSelection() -> String?

    /// Get selected text (alias)
    func getSelectedText() -> String?

    /// Clear selection
    func clearSelection()

    /// Clear selection (alias)
    func selectNone()

    /// Select the current command (for Cmd+A)
    func selectCurrentCommand()

    /// Clear command selection state without visual change
    func clearCommandSelectionState()

    // MARK: - Scrolling Methods

    /// Scroll to position (0.0 = bottom, 1.0 = top)
    func scroll(toPosition position: Double)

    /// Scroll up by lines
    func scrollUp(lines: Int)

    /// Scroll down by lines
    func scrollDown(lines: Int)

    /// Scroll to top of history
    func scrollToTop()

    /// Scroll to bottom (current)
    func scrollToBottom()

    /// Scroll so that `absoluteRow` is at the top of the viewport.
    func scrollToRow(absoluteRow: Int)

    /// Scroll to the nearest input line above the current viewport top.
    func scrollToPreviousInputLine()

    /// Scroll to the nearest input line below the current viewport top.
    func scrollToNextInputLine()

    // MARK: - Configuration Methods

    /// Apply a color scheme
    func applyColorScheme(_ scheme: TerminalColorScheme)

    /// Configure cursor style
    func applyCursorStyle(style: String, blink: Bool)

    /// Configure bell settings
    func applyBellSettings(enabled: Bool, sound: String)

    /// Configure scrollback buffer size
    func applyScrollbackLines(_ lines: Int)

    // MARK: - Cursor Line Highlight

    /// Attach a cursor line view for highlighting
    func attachCursorLineView(_ view: TerminalCursorLineView)

    /// Configure cursor line highlight options
    func configureCursorLineHighlight(contextLines: Bool, inputHistory: Bool)

    /// Enable or disable cursor line highlighting
    func setCursorLineHighlightEnabled(_ enabled: Bool)

    /// Record the current input line for history tracking
    func recordInputLine()

    // MARK: - Event Monitoring

    /// Enable or disable event monitoring (mouse, keyboard)
    func setEventMonitoringEnabled(_ enabled: Bool)

    /// Install history key monitor for command history navigation
    func installHistoryKeyMonitor()

    // MARK: - Snippets

    /// Insert a snippet with placeholder navigation
    func insertSnippet(_ insertion: SnippetInsertion)

    // MARK: - Scrollback Management

    /// Clear the scrollback buffer
    func clearScrollbackBuffer()

    // MARK: - Security

    /// Returns true when the PTY has echo disabled (e.g., password prompt, passphrase entry).
    /// Commands entered while echo is disabled should NOT be recorded in history.
    var isPtyEchoDisabled: Bool { get }
}

extension TerminalViewLike {
    func captureRemoteGridSnapshotPayload() -> Data? {
        nil
    }
}

// MARK: - RustTerminalView Conformance

extension RustTerminalView: TerminalViewLike {
    // All methods already exist with matching signatures on RustTerminalView.
}
