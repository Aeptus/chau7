import AppKit
import SwiftUI
import Carbon

// MARK: - F04: Quick Dropdown Terminal

/// Manages the dropdown terminal window with global hotkey support
final class DropdownController {
    static let shared = DropdownController()

    private var dropdownWindow: NSWindow?
    private var tabsModel: OverlayTabsModel?
    private weak var appModel: AppModel?
    private var globalHotkeyMonitor: Any?
    private var isVisible: Bool = false
    private var hotkeyEventHandler: EventHandlerRef?

    private init() {}

    // MARK: - Setup

    func setup(appModel: AppModel) {
        self.appModel = appModel

        // Only setup if dropdown is enabled
        guard FeatureSettings.shared.isDropdownEnabled else {
            Log.info("F04: Dropdown terminal disabled in settings.")
            return
        }

        registerGlobalHotkey()
        Log.info("F04: Dropdown controller initialized.")
    }

    func cleanup() {
        unregisterGlobalHotkey()
        dropdownWindow?.close()
        dropdownWindow = nil
        tabsModel = nil
        Log.info("F04: Dropdown controller cleaned up.")
    }

    // MARK: - Global Hotkey Registration

    private func registerGlobalHotkey() {
        unregisterGlobalHotkey()

        // Parse hotkey string from settings
        let hotkeyString = FeatureSettings.shared.dropdownHotkey
        guard let (keyCode, modifiers) = parseHotkeyString(hotkeyString) else {
            Log.warn("F04: Could not parse hotkey '\(hotkeyString)', using default Ctrl+`")
            registerWithCarbon(keyCode: UInt32(kVK_ANSI_Grave), modifiers: UInt32(controlKey))
            return
        }

        registerWithCarbon(keyCode: keyCode, modifiers: modifiers)
    }

    private func registerWithCarbon(keyCode: UInt32, modifiers: UInt32) {
        // Note: Carbon EventHotKeyRef requires more complex setup with C callbacks.
        // Using NSEvent monitors instead for simplicity and modern macOS compatibility.
        _ = (keyCode, modifiers)  // Silence unused parameter warnings
        globalHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleGlobalKeyEvent(event)
        }

        // Also add local monitor for when our app is active
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.shouldHandleAsDropdownHotkey(event) == true {
                self?.toggleDropdown()
                return nil
            }
            return event
        }

        Log.info("F04: Registered global hotkey monitor.")
    }

    private func unregisterGlobalHotkey() {
        if let monitor = globalHotkeyMonitor {
            NSEvent.removeMonitor(monitor)
            globalHotkeyMonitor = nil
        }
    }

    private func handleGlobalKeyEvent(_ event: NSEvent) {
        guard FeatureSettings.shared.isDropdownEnabled else { return }
        if shouldHandleAsDropdownHotkey(event) {
            toggleDropdown()
        }
    }

    private func shouldHandleAsDropdownHotkey(_ event: NSEvent) -> Bool {
        let hotkeyString = FeatureSettings.shared.dropdownHotkey
        guard let (expectedKeyCode, expectedModifiers) = parseHotkeyString(hotkeyString) else {
            // Default: Ctrl+`
            return event.keyCode == UInt16(kVK_ANSI_Grave) &&
                   event.modifierFlags.contains(.control) &&
                   !event.modifierFlags.contains(.command) &&
                   !event.modifierFlags.contains(.option) &&
                   !event.modifierFlags.contains(.shift)
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Check modifiers
        var requiredFlags: NSEvent.ModifierFlags = []
        if expectedModifiers & UInt32(controlKey) != 0 { requiredFlags.insert(.control) }
        if expectedModifiers & UInt32(cmdKey) != 0 { requiredFlags.insert(.command) }
        if expectedModifiers & UInt32(optionKey) != 0 { requiredFlags.insert(.option) }
        if expectedModifiers & UInt32(shiftKey) != 0 { requiredFlags.insert(.shift) }

        return event.keyCode == UInt16(expectedKeyCode) && flags == requiredFlags
    }

    private func parseHotkeyString(_ str: String) -> (keyCode: UInt32, modifiers: UInt32)? {
        let parts = str.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty else { return nil }

        var modifiers: UInt32 = 0
        var keyString: String?

        for part in parts {
            switch part {
            case "ctrl", "control":
                modifiers |= UInt32(controlKey)
            case "cmd", "command":
                modifiers |= UInt32(cmdKey)
            case "opt", "option", "alt":
                modifiers |= UInt32(optionKey)
            case "shift":
                modifiers |= UInt32(shiftKey)
            default:
                keyString = part
            }
        }

        guard let key = keyString else { return nil }

        // Map key string to key code
        let keyCode: UInt32
        switch key {
        case "`", "grave", "backtick":
            keyCode = UInt32(kVK_ANSI_Grave)
        case "space":
            keyCode = UInt32(kVK_Space)
        case "tab":
            keyCode = UInt32(kVK_Tab)
        case "escape", "esc":
            keyCode = UInt32(kVK_Escape)
        case "f1": keyCode = UInt32(kVK_F1)
        case "f2": keyCode = UInt32(kVK_F2)
        case "f3": keyCode = UInt32(kVK_F3)
        case "f4": keyCode = UInt32(kVK_F4)
        case "f5": keyCode = UInt32(kVK_F5)
        case "f6": keyCode = UInt32(kVK_F6)
        case "f7": keyCode = UInt32(kVK_F7)
        case "f8": keyCode = UInt32(kVK_F8)
        case "f9": keyCode = UInt32(kVK_F9)
        case "f10": keyCode = UInt32(kVK_F10)
        case "f11": keyCode = UInt32(kVK_F11)
        case "f12": keyCode = UInt32(kVK_F12)
        default:
            // Single letter keys
            if key.count == 1, let char = key.first {
                if let code = keyCodeForCharacter(char) {
                    keyCode = UInt32(code)
                } else {
                    return nil
                }
            } else {
                return nil
            }
        }

        return (keyCode, modifiers)
    }

    private func keyCodeForCharacter(_ char: Character) -> Int? {
        let map: [Character: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
            "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
            "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
            "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
            "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
            "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
            "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        ]
        return map[char]
    }

    // MARK: - Toggle Dropdown

    func toggleDropdown() {
        guard FeatureSettings.shared.isDropdownEnabled else { return }

        if isVisible {
            hideDropdown()
        } else {
            showDropdown()
        }
    }

    private func showDropdown() {
        guard let appModel else {
            Log.warn("F04: Cannot show dropdown - AppModel not available.")
            return
        }

        // Create window if needed
        if dropdownWindow == nil {
            createDropdownWindow(appModel: appModel)
        }

        guard let window = dropdownWindow else { return }

        // Position at top of screen
        positionDropdownWindow(window)

        // Animate in
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }

        tabsModel?.focusSelected()
        isVisible = true
        Log.info("F04: Dropdown shown.")
    }

    private func hideDropdown() {
        guard let window = dropdownWindow else { return }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: {
            window.orderOut(nil)
        })

        isVisible = false
        Log.info("F04: Dropdown hidden.")
    }

    private func createDropdownWindow(appModel: AppModel) {
        let model = OverlayTabsModel(appModel: appModel)
        self.tabsModel = model

        let overlay = Chau7OverlayView(overlayModel: model, appModel: appModel)
        let hostingView = NSHostingView(rootView: overlay)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: blur.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: blur.bottomAnchor)
        ])

        let screen = NSScreen.main ?? NSScreen.screens.first!
        let screenFrame = screen.frame

        let heightPercent = FeatureSettings.shared.dropdownHeight
        let height = screenFrame.height * CGFloat(heightPercent)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: screenFrame.maxY - height, width: screenFrame.width, height: height),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Chau7 Dropdown"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = false
        window.contentView = blur

        model.overlayWindow = window
        self.dropdownWindow = window

        Log.info("F04: Dropdown window created.")
    }

    private func positionDropdownWindow(_ window: NSWindow) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        let screenFrame = screen.frame
        let heightPercent = FeatureSettings.shared.dropdownHeight
        let height = screenFrame.height * CGFloat(heightPercent)

        window.setFrame(
            NSRect(x: screenFrame.minX, y: screenFrame.maxY - height, width: screenFrame.width, height: height),
            display: true
        )
    }

    // MARK: - Reconfigure

    func reconfigure() {
        if FeatureSettings.shared.isDropdownEnabled {
            registerGlobalHotkey()
        } else {
            unregisterGlobalHotkey()
            hideDropdown()
        }
    }
}
