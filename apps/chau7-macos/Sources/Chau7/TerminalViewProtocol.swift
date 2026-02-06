import AppKit
import SwiftTerm

// MARK: - Unified Terminal View Protocol

/// Protocol that defines the common interface for terminal views.
/// Both Chau7TerminalView (SwiftTerm) and RustTerminalView conform to this protocol,
/// enabling backend-agnostic code in the session model and UI layers.
///
/// This protocol is the single source of truth for terminal view capabilities.
/// It consolidates the existing `HighlightTerminalView` and `CursorLineTerminalView`
/// protocols while adding all the methods needed by `TerminalSessionModel`.
protocol TerminalViewLike: NSView {
    // MARK: - Callbacks

    /// Called when PTY output is received
    var onOutput: ((Data) -> Void)? { get set }

    /// Called when user input is sent
    var onInput: ((String) -> Void)? { get set }

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

    // MARK: - Terminal Access

    /// Returns the underlying SwiftTerm Terminal for buffer access
    /// Note: For RustTerminalView, this returns a HeadlessTerminal that mirrors Rust state
    func getTerminal() -> Terminal

    // MARK: - Input Methods

    /// Send raw bytes to the PTY
    func send(data bytes: [UInt8])

    /// Send text to the PTY
    func send(txt text: String)

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
}

// MARK: - Chau7TerminalView Conformance

extension Chau7TerminalView: TerminalViewLike {
    // Bridge method: Convert [UInt8] to ArraySlice for SwiftTerm's base class
    // SwiftTerm's send(data:) takes ArraySlice<UInt8>, but our protocol uses [UInt8]
    func send(data bytes: [UInt8]) {
        // Call the parent class method by converting array to slice
        send(data: bytes[...])
    }
}

// MARK: - RustTerminalView Conformance

extension RustTerminalView: TerminalViewLike {
    // Most methods already exist with matching signatures.
    // Only need explicit conformance declaration.
}

// MARK: - Deprecated Protocol Aliases

/// Deprecated: Use `TerminalViewLike` instead.
/// This protocol is kept for backwards compatibility with existing highlight views.
typealias HighlightTerminalView = TerminalViewLike

/// Deprecated: Use `TerminalViewLike` instead.
/// This protocol is kept for backwards compatibility with existing cursor line views.
typealias CursorLineTerminalView = TerminalViewLike
