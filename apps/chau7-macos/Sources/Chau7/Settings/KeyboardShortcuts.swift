import AppKit

/// Central registry of all keyboard shortcuts in the app.
/// This file documents shortcuts and provides constants for consistency.
///
/// ## Shortcut Locations
/// - SwiftUI .commands{} in Chau7App.swift: Most menu shortcuts
/// - AppDelegate.handleKeyEvent(): Shortcuts requiring special handling (Cmd+W, Cmd+K, Ctrl+Tab, Escape)
///
/// ## Complete Shortcut List
///
/// ### Window/Tab Management
/// - Cmd+N: New Window
/// - Cmd+T: New Tab
/// - Cmd+W: Close Tab (handled specially to prevent window close)
/// - Cmd+1-9: Switch to Tab 1-9
/// - Cmd+Shift+]: Next Tab
/// - Cmd+Shift+[: Previous Tab
/// - Cmd+Option+Right: Next Tab
/// - Cmd+Option+Left: Previous Tab
/// - Ctrl+Tab: Next Tab
/// - Ctrl+Shift+Tab: Previous Tab
/// - Cmd+/: Keyboard Shortcuts
/// - Cmd+Option+E: Open Text Editor pane
///
/// ### Edit
/// - Cmd+C: Copy (or interrupt if no selection)
/// - Cmd+V: Paste
/// - Cmd+F: Find
/// - Cmd+G: Find Next
/// - Cmd+Shift+G: Find Previous
/// - Cmd+Shift+S: Snippets
/// - Cmd+Shift+R: Rename Tab
/// - Escape: Close search/rename overlay
///
/// ### View
/// - Cmd+=: Zoom In
/// - Cmd+Shift+=: Zoom In (alternative)
/// - Cmd+-: Zoom Out
/// - Cmd+0: Reset Zoom
/// - Cmd+K: Clear Scrollback
///
/// ### App
/// - Cmd+,: Settings
///
enum KeyboardShortcuts {
    // MARK: - Key Codes (for NSEvent handling)

    /// Escape key code
    static let escapeKeyCode: UInt16 = 53
    /// Tab key code
    static let tabKeyCode: UInt16 = 48
    /// Left arrow key code
    static let leftArrowKeyCode: UInt16 = 123
    /// Right arrow key code
    static let rightArrowKeyCode: UInt16 = 124

    // MARK: - Character Constants

    struct Characters {
        static let newWindow = "n"
        static let newTab = "t"
        static let closeTab = "w"
        static let copy = "c"
        static let paste = "v"
        static let find = "f"
        static let findNext = "g"
        static let zoomIn = "="
        static let zoomOut = "-"
        static let zoomReset = "0"
        static let clearScrollback = "k"
        static let settings = ","
        static let renameTab = "r"
        static let snippets = "s"
        static let nextTab = "]"
        static let previousTab = "["
    }
}
