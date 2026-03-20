import AppKit

/// Central registry of all keyboard shortcuts in the app.
/// This file documents shortcuts and provides constants for consistency.
///
/// ## Convention
/// - **Cmd** alone: Standard macOS actions (Copy, Paste, Find, Close)
/// - **Cmd+Shift**: Standard extended actions (Reopen Tab, Export, Find Previous)
/// - **Cmd+Option**: Chau7-specific features
/// - **Cmd+Option+Shift**: Chau7 recovery/rare actions
/// - **Cmd+Ctrl**: Window chrome (Fullscreen, Close Pane)
///
/// ## Shortcut Locations
/// - SwiftUI .commands{} in Chau7App.swift: Menu shortcuts
/// - AppDelegate.handleKeyEvent(): Special handling (Cmd+W, Ctrl+Tab, Escape, Cmd+1-9)
/// - FeatureSettings.swift: F11 customizable keybindings (user can rebind)
///
/// ## Complete Shortcut List
///
/// ### Standard macOS (Cmd / Cmd+Shift)
/// - Cmd+N: New Window
/// - Cmd+T: New Tab
/// - Cmd+W: Close Tab
/// - Cmd+Shift+W: Close Window
/// - Cmd+Shift+T: Reopen Closed Tab
/// - Cmd+1-9: Switch to Tab 1-9 (international — works on all layouts)
/// - Cmd+Shift+]: Next Tab
/// - Cmd+Shift+[: Previous Tab
/// - Ctrl+Tab / Ctrl+Shift+Tab: Next/Previous Tab
/// - Cmd+C: Copy (or interrupt if no selection)
/// - Cmd+V: Paste
/// - Cmd+X: Cut
/// - Cmd+A: Select All
/// - Cmd+F: Find
/// - Cmd+G: Find Next
/// - Cmd+Shift+G: Find Previous
/// - Cmd+E: Use Selection for Find
/// - Cmd+K: Clear Screen
/// - Cmd+D: Split Horizontally
/// - Cmd+=/-: Zoom In/Out
/// - Cmd+Ctrl+F: Fullscreen
/// - Cmd+Shift+O: SSH Connections
/// - Cmd+Shift+S: Export Text
/// - Cmd+P: Print
/// - Cmd+,: Settings
/// - Cmd+/: Keyboard Shortcuts
/// - Escape: Close search/rename overlay
///
/// ### Chau7-specific (Cmd+Option)
/// - Cmd+Option+P: Command Palette
/// - Cmd+Option+K: Clear Scrollback
/// - Cmd+Option+D: Split Vertically
/// - Cmd+Option+R: Rename Tab
/// - Cmd+Option+L: Debug Console
/// - Cmd+Option+G: Show Changed Files
/// - Cmd+Option+E: Open Text Editor
/// - Cmd+Option+V: Paste Escaped
/// - Cmd+Option+W: Close Other Tabs
/// - Cmd+Option+]/[: Focus Next/Previous Pane
/// - Cmd+Option+Shift+E: Append Selection to Editor
/// - Cmd+Option+Shift+R: Refresh Tab Bar (recovery)
/// - Cmd+Option+Shift+]/[: Move Tab Right/Left
/// - Cmd+Ctrl+W: Close Pane
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

    enum Characters {
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
