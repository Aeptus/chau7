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
    case nextTab
    case previousTab
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
    case toggleDropdown
    case toggleBroadcast
    case showClipboardHistory
    case showBookmarks
    case addBookmark
    case showSnippets
    case renameTab

    // Window
    case closeWindow
    case newWindow

    var displayName: String {
        switch self {
        case .newTab: return "New Tab"
        case .closeTab: return "Close Tab"
        case .nextTab: return "Next Tab"
        case .previousTab: return "Previous Tab"
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
        case .toggleDropdown: return "Toggle Dropdown"
        case .toggleBroadcast: return "Toggle Broadcast"
        case .showClipboardHistory: return "Clipboard History"
        case .showBookmarks: return "Bookmarks"
        case .addBookmark: return "Add Bookmark"
        case .showSnippets: return "Snippets"
        case .renameTab: return "Rename Tab"
        case .closeWindow: return "Close Window"
        case .newWindow: return "New Window"
        }
    }
}

/// Manages keybinding presets and active bindings
final class KeybindingsManager: ObservableObject {
    static let shared = KeybindingsManager()

    @Published private(set) var activeBindings: [KeyBinding] = []
    @Published var currentPreset: String = "default" {
        didSet {
            loadPreset(currentPreset)
            FeatureSettings.shared.keybindingPreset = currentPreset
        }
    }

    // MARK: - Preset Definitions

    private static let defaultBindings: [(String, KeyAction)] = [
        // Tab management
        ("cmd+t", .newTab),
        ("cmd+w", .closeTab),
        ("ctrl+tab", .nextTab),
        ("ctrl+shift+tab", .previousTab),
        ("cmd+1", .selectTab1),
        ("cmd+2", .selectTab2),
        ("cmd+3", .selectTab3),
        ("cmd+4", .selectTab4),
        ("cmd+5", .selectTab5),
        ("cmd+6", .selectTab6),
        ("cmd+7", .selectTab7),
        ("cmd+8", .selectTab8),
        ("cmd+9", .selectTab9),

        // Editing
        ("cmd+c", .copy),
        ("cmd+v", .paste),
        ("cmd+a", .selectAll),
        ("cmd+k", .clear),

        // Search
        ("cmd+f", .toggleSearch),
        ("cmd+g", .nextMatch),
        ("cmd+shift+g", .previousMatch),

        // View
        ("cmd+=", .zoomIn),
        ("cmd+-", .zoomOut),
        ("cmd+0", .zoomReset),
        ("cmd+ctrl+f", .toggleFullscreen),

        // Features
        ("cmd+shift+b", .toggleBroadcast),
        ("cmd+shift+v", .showClipboardHistory),
        ("cmd+b", .showBookmarks),
        ("cmd+shift+a", .addBookmark),
        ("cmd+shift+s", .showSnippets),
        ("cmd+shift+r", .renameTab),

        // Window
        ("cmd+shift+w", .closeWindow),
        ("cmd+n", .newWindow),
    ]

    private static let vimBindings: [(String, KeyAction)] = [
        // Vim-style navigation with Ctrl
        ("ctrl+h", .previousTab),  // hjkl style
        ("ctrl+l", .nextTab),

        // Include all default bindings
    ] + defaultBindings

    private static let emacsBindings: [(String, KeyAction)] = [
        // Emacs-style
        ("ctrl+a", .selectAll),  // Actually start of line in emacs, but for terminal...
        ("ctrl+e", .toggleSearch),  // End of line -> search
        ("ctrl+n", .nextTab),
        ("ctrl+p", .previousTab),

        // Include most default bindings
    ] + defaultBindings.filter { $0.1 != .selectAll }

    // MARK: - Initialization

    private init() {
        currentPreset = FeatureSettings.shared.keybindingPreset
        loadPreset(currentPreset)
    }

    // MARK: - Preset Management

    func loadPreset(_ name: String) {
        let bindings: [(String, KeyAction)]

        switch name {
        case "vim":
            bindings = Self.vimBindings
        case "emacs":
            bindings = Self.emacsBindings
        default:
            bindings = Self.defaultBindings
        }

        activeBindings = bindings.compactMap { KeyBinding.parse($0.0, action: $0.1) }
        Log.info("F11: Loaded '\(name)' keybinding preset with \(activeBindings.count) bindings.")
    }

    // MARK: - Event Handling

    /// Returns the action for the given event, or nil if no binding matches
    func actionForEvent(_ event: NSEvent) -> KeyAction? {
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
            delegate?.closeTab()
        case .nextTab:
            delegate?.nextTab()
        case .previousTab:
            delegate?.previousTab()
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
            overlayModel?.selectedTab?.session.sendInput("\u{03}")  // Ctrl+C
        case .eof:
            overlayModel?.selectedTab?.session.sendInput("\u{04}")  // Ctrl+D
        case .suspend:
            overlayModel?.selectedTab?.session.sendInput("\u{1A}")  // Ctrl+Z
        case .clearLine:
            overlayModel?.selectedTab?.session.sendInput("\u{15}")  // Ctrl+U
        case .clearWord:
            overlayModel?.selectedTab?.session.sendInput("\u{17}")  // Ctrl+W

        // Features
        case .toggleDropdown:
            delegate?.toggleDropdown()
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
