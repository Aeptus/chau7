import AppKit
import Carbon

// MARK: - F11: Keybindings System

/// Represents a keyboard shortcut
struct KeyBinding: Equatable {
    let key: String  // e.g., "c", "v", "w", "escape"
    let modifiers: NSEvent.ModifierFlags
    let action: KeyAction

    /// Creates a KeyBinding from a string like "cmd+c", "ctrl+shift+t", etc.
    static func parse(_ str: String, action: KeyAction) -> KeyBinding? {
        let parts = str.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty else { return nil }

        var modifiers: NSEvent.ModifierFlags = []
        var keyString: String?

        for part in parts {
            switch part {
            case "ctrl", "control":
                modifiers.insert(.control)
            case "cmd", "command":
                modifiers.insert(.command)
            case "opt", "option", "alt":
                modifiers.insert(.option)
            case "shift":
                modifiers.insert(.shift)
            default:
                keyString = part
            }
        }

        guard let key = keyString else { return nil }
        return KeyBinding(key: key, modifiers: modifiers, action: action)
    }

    static func modifiers(from parts: [String]) -> NSEvent.ModifierFlags {
        var modifiers: NSEvent.ModifierFlags = []
        for part in parts.map({ $0.lowercased() }) {
            switch part {
            case "ctrl", "control":
                modifiers.insert(.control)
            case "cmd", "command":
                modifiers.insert(.command)
            case "opt", "option", "alt":
                modifiers.insert(.option)
            case "shift":
                modifiers.insert(.shift)
            default:
                break
            }
        }
        return modifiers
    }

    /// Checks if this binding matches the given event
    func matches(_ event: NSEvent) -> Bool {
        let eventFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard eventFlags == modifiers else { return false }

        let eventKey = event.charactersIgnoringModifiers?.lowercased() ?? ""

        // Handle special keys
        switch key {
        case "escape", "esc":
            return event.keyCode == UInt16(kVK_Escape)
        case "tab":
            return event.keyCode == UInt16(kVK_Tab)
        case "space":
            return event.keyCode == UInt16(kVK_Space)
        case "enter", "return":
            return event.keyCode == UInt16(kVK_Return)
        case "backspace", "delete":
            return event.keyCode == UInt16(kVK_Delete)
        case "up":
            return event.keyCode == UInt16(kVK_UpArrow)
        case "down":
            return event.keyCode == UInt16(kVK_DownArrow)
        case "left":
            return event.keyCode == UInt16(kVK_LeftArrow)
        case "right":
            return event.keyCode == UInt16(kVK_RightArrow)
        default:
            return eventKey == key
        }
    }
}

/// Terminal actions that can be bound to keys
enum KeyAction: String, CaseIterable {
    // Tab management
    case newTab
    case closeTab
    case reopenClosedTab
    case nextTab
    case previousTab
    case refreshTabBar  // Recovery: force re-render of tab bar
    case selectTab1, selectTab2, selectTab3, selectTab4
    case selectTab5, selectTab6, selectTab7, selectTab8, selectTab9

    // Editing
    case copy
    case paste
    case selectAll
    case clear

    // Search
    case toggleSearch
    case nextMatch
    case previousMatch

    // View
    case zoomIn
    case zoomOut
    case zoomReset
    case toggleFullscreen

    // Terminal
    case interrupt  // Ctrl+C
    case eof        // Ctrl+D
    case suspend    // Ctrl+Z
    case clearLine  // Ctrl+U
    case clearWord  // Ctrl+W

    // Features
    case toggleBroadcast
    case showClipboardHistory
    case showBookmarks
    case addBookmark
    case showSnippets
    case renameTab
    case debugConsole
    case splitHorizontal
    case splitVertical
    case openTextEditor

    // Navigation
    case previousInputLine
    case nextInputLine

    // Window
    case closeWindow
    case newWindow

    var displayName: String {
        switch self {
        case .newTab: return "New Tab"
        case .closeTab: return "Close Tab"
        case .reopenClosedTab: return "Reopen Closed Tab"
        case .nextTab: return "Next Tab"
        case .previousTab: return "Previous Tab"
        case .refreshTabBar: return "Refresh Tab Bar"
        case .selectTab1: return "Select Tab 1"
        case .selectTab2: return "Select Tab 2"
        case .selectTab3: return "Select Tab 3"
        case .selectTab4: return "Select Tab 4"
        case .selectTab5: return "Select Tab 5"
        case .selectTab6: return "Select Tab 6"
        case .selectTab7: return "Select Tab 7"
        case .selectTab8: return "Select Tab 8"
        case .selectTab9: return "Select Tab 9"
        case .copy: return "Copy"
        case .paste: return "Paste"
        case .selectAll: return "Select All"
        case .clear: return "Clear Screen"
        case .toggleSearch: return "Find"
        case .nextMatch: return "Find Next"
        case .previousMatch: return "Find Previous"
        case .zoomIn: return "Zoom In"
        case .zoomOut: return "Zoom Out"
        case .zoomReset: return "Reset Zoom"
        case .toggleFullscreen: return "Toggle Fullscreen"
        case .interrupt: return "Interrupt (SIGINT)"
        case .eof: return "End of File"
        case .suspend: return "Suspend"
        case .clearLine: return "Clear Line"
        case .clearWord: return "Clear Word"
        case .toggleBroadcast: return "Toggle Broadcast"
        case .showClipboardHistory: return "Clipboard History"
        case .showBookmarks: return "Bookmarks"
        case .addBookmark: return "Add Bookmark"
        case .showSnippets: return "Snippets"
        case .renameTab: return "Rename Tab"
        case .debugConsole: return "Debug Console"
        case .splitHorizontal: return "Split Horizontal"
        case .splitVertical: return "Split Vertical"
        case .openTextEditor: return "Open Text Editor"
        case .previousInputLine: return "Previous Input Line"
        case .nextInputLine: return "Next Input Line"
        case .closeWindow: return "Close Window"
        case .newWindow: return "New Window"
        }
    }

    static func fromShortcutAction(_ action: String) -> KeyAction? {
        switch action {
        case "newTab": return .newTab
        case "closeTab": return .closeTab
        case "reopenClosedTab": return .reopenClosedTab
        case "nextTab": return .nextTab
        case "previousTab": return .previousTab
        case "refreshTabBar": return .refreshTabBar
        case "find": return .toggleSearch
        case "findNext": return .nextMatch
        case "findPrevious": return .previousMatch
        case "copy": return .copy
        case "paste": return .paste
        case "clear": return .clear
        case "zoomIn": return .zoomIn
        case "zoomOut": return .zoomOut
        case "zoomReset": return .zoomReset
        case "snippets": return .showSnippets
        case "renameTab": return .renameTab
        case "debugConsole": return .debugConsole
        case "newWindow": return .newWindow
        case "splitHorizontal": return .splitHorizontal
        case "splitVertical": return .splitVertical
        case "openTextEditor": return .openTextEditor
        case "previousInputLine": return .previousInputLine
        case "nextInputLine": return .nextInputLine
        default: return nil
        }
    }
}

/// Manages keybindings and active bindings
final class KeybindingsManager: ObservableObject {
    static let shared = KeybindingsManager()

    @Published private(set) var activeBindings: [KeyBinding] = []
    private var shortcutsSignature: String = ""

    // MARK: - Initialization

    private init() {
        refreshBindings(force: true)
    }

    private func refreshBindings(force: Bool = false) {
        let shortcuts = FeatureSettings.shared.customShortcuts
        let signature = shortcutsSignature(for: shortcuts)
        guard force || signature != shortcutsSignature else { return }

        shortcutsSignature = signature
        activeBindings = shortcuts.compactMap { binding(from: $0) }
        Log.info("F11: Loaded \(activeBindings.count) keybindings from settings.")
    }

    private func shortcutsSignature(for shortcuts: [KeyboardShortcut]) -> String {
        shortcuts.map {
            "\($0.action)|\($0.key.lowercased())|\($0.modifiers.sorted().joined(separator: ","))"
        }.joined(separator: ";")
    }

    private func binding(from shortcut: KeyboardShortcut) -> KeyBinding? {
        guard let action = KeyAction.fromShortcutAction(shortcut.action) else { return nil }
        let modifiers = KeyBinding.modifiers(from: shortcut.modifiers)
        return KeyBinding(key: shortcut.key.lowercased(), modifiers: modifiers, action: action)
    }

    // MARK: - Event Handling

    /// Returns the action for the given event, or nil if no binding matches
    func actionForEvent(_ event: NSEvent) -> KeyAction? {
        refreshBindings()
        for binding in activeBindings {
            if binding.matches(event) {
                return binding.action
            }
        }
        return nil
    }

    /// Executes the action associated with an event
    /// Returns true if an action was executed, false otherwise
    func handleEvent(_ event: NSEvent, delegate: AppDelegate?, overlayModel: OverlayTabsModel?) -> Bool {
        guard let action = actionForEvent(event) else { return false }

        executeAction(action, delegate: delegate, overlayModel: overlayModel)
        return true
    }

    /// Executes a key action
    func executeAction(_ action: KeyAction, delegate: AppDelegate?, overlayModel: OverlayTabsModel?) {
        switch action {
        // Tab management
        case .newTab:
            delegate?.newTab()
        case .closeTab:
            delegate?.closeTabFromShortcut()
        case .reopenClosedTab:
            delegate?.reopenClosedTab()
        case .nextTab:
            delegate?.nextTab()
        case .previousTab:
            delegate?.previousTab()
        case .refreshTabBar:
            overlayModel?.refreshTabBar()
        case .selectTab1:
            delegate?.selectTab(number: 1)
        case .selectTab2:
            delegate?.selectTab(number: 2)
        case .selectTab3:
            delegate?.selectTab(number: 3)
        case .selectTab4:
            delegate?.selectTab(number: 4)
        case .selectTab5:
            delegate?.selectTab(number: 5)
        case .selectTab6:
            delegate?.selectTab(number: 6)
        case .selectTab7:
            delegate?.selectTab(number: 7)
        case .selectTab8:
            delegate?.selectTab(number: 8)
        case .selectTab9:
            delegate?.selectTab(number: 9)

        // Editing
        case .copy:
            delegate?.copyOrInterrupt()
        case .paste:
            delegate?.paste()
        case .selectAll:
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        case .clear:
            delegate?.clearScrollback()

        // Search
        case .toggleSearch:
            delegate?.toggleSearch()
        case .nextMatch:
            delegate?.nextSearchMatch()
        case .previousMatch:
            delegate?.previousSearchMatch()

        // View
        case .zoomIn:
            delegate?.zoomIn()
        case .zoomOut:
            delegate?.zoomOut()
        case .zoomReset:
            delegate?.zoomReset()
        case .toggleFullscreen:
            NSApp.keyWindow?.toggleFullScreen(nil)

        // Terminal signals - send control codes to the terminal
        case .interrupt:
            overlayModel?.selectedTab?.session?.sendInput("\u{03}")  // Ctrl+C
        case .eof:
            overlayModel?.selectedTab?.session?.sendInput("\u{04}")  // Ctrl+D
        case .suspend:
            overlayModel?.selectedTab?.session?.sendInput("\u{1A}")  // Ctrl+Z
        case .clearLine:
            overlayModel?.selectedTab?.session?.sendInput("\u{15}")  // Ctrl+U
        case .clearWord:
            overlayModel?.selectedTab?.session?.sendInput("\u{17}")  // Ctrl+W

        // Features
        case .toggleBroadcast:
            overlayModel?.toggleBroadcast()
        case .showClipboardHistory:
            overlayModel?.toggleClipboardHistory()
        case .showBookmarks:
            overlayModel?.toggleBookmarkList()
        case .addBookmark:
            overlayModel?.addBookmark()
        case .showSnippets:
            overlayModel?.toggleSnippetManager()
        case .renameTab:
            delegate?.beginRenameTab()
        case .debugConsole:
            DebugConsoleController.shared.toggle()
        case .splitHorizontal:
            delegate?.splitHorizontally()
        case .splitVertical:
            delegate?.splitVertically()
        case .openTextEditor:
            delegate?.openTextEditorPane()

        // Navigation
        case .previousInputLine:
            delegate?.scrollToPreviousInputLine()
        case .nextInputLine:
            delegate?.scrollToNextInputLine()

        // Window
        case .closeWindow:
            delegate?.closeWindow()
        case .newWindow:
            delegate?.newOverlayWindow()
        }

        Log.trace("F11: Executed action '\(action.rawValue)'")
    }

    // MARK: - Custom Bindings

    /// Get all available presets
    static var availablePresets: [String] {
        ["default", "vim", "emacs"]
    }

    /// Get the default binding string for an action
    func defaultBindingString(for action: KeyAction) -> String? {
        if let binding = activeBindings.first(where: { $0.action == action }) {
            return formatBinding(binding)
        }
        return nil
    }

    // Modifier display order for consistent formatting
    private static let modifierOrder: [(NSEvent.ModifierFlags, String)] = [
        (.control, "Ctrl"),
        (.option, "Opt"),
        (.shift, "Shift"),
        (.command, "Cmd")
    ]

    private func formatBinding(_ binding: KeyBinding) -> String {
        let mods = Self.modifierOrder.compactMap { flag, name in
            binding.modifiers.contains(flag) ? name : nil
        }
        return (mods + [binding.key.uppercased()]).joined(separator: "+")
    }
}
