import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7

@MainActor
final class KeybindingsManagerTests: XCTestCase {

    // MARK: - Singleton

    func testSharedReturnsSameInstance() {
        let a = KeybindingsManager.shared
        let b = KeybindingsManager.shared
        XCTAssertTrue(a === b, "shared should return the same instance")
    }

    // MARK: - Default Bindings Loaded

    func testActiveBindingsNotEmpty() {
        let manager = KeybindingsManager.shared
        XCTAssertFalse(manager.activeBindings.isEmpty,
            "activeBindings should be populated from default shortcuts")
    }

    func testActiveBindingsContainNewTab() {
        let manager = KeybindingsManager.shared
        let hasNewTab = manager.activeBindings.contains { $0.action == .newTab }
        XCTAssertTrue(hasNewTab, "Default bindings should include newTab")
    }

    func testActiveBindingsContainCloseTab() {
        let manager = KeybindingsManager.shared
        let hasCloseTab = manager.activeBindings.contains { $0.action == .closeTab }
        XCTAssertTrue(hasCloseTab, "Default bindings should include closeTab")
    }

    func testActiveBindingsContainCopy() {
        let manager = KeybindingsManager.shared
        let hasCopy = manager.activeBindings.contains { $0.action == .copy }
        XCTAssertTrue(hasCopy, "Default bindings should include copy")
    }

    func testActiveBindingsContainPaste() {
        let manager = KeybindingsManager.shared
        let hasPaste = manager.activeBindings.contains { $0.action == .paste }
        XCTAssertTrue(hasPaste, "Default bindings should include paste")
    }

    func testActiveBindingsContainFind() {
        let manager = KeybindingsManager.shared
        let hasFind = manager.activeBindings.contains { $0.action == .toggleSearch }
        XCTAssertTrue(hasFind, "Default bindings should include toggleSearch (find)")
    }

    func testActiveBindingsContainZoom() {
        let manager = KeybindingsManager.shared
        let hasZoomIn = manager.activeBindings.contains { $0.action == .zoomIn }
        let hasZoomOut = manager.activeBindings.contains { $0.action == .zoomOut }
        let hasZoomReset = manager.activeBindings.contains { $0.action == .zoomReset }
        XCTAssertTrue(hasZoomIn, "Default bindings should include zoomIn")
        XCTAssertTrue(hasZoomOut, "Default bindings should include zoomOut")
        XCTAssertTrue(hasZoomReset, "Default bindings should include zoomReset")
    }

    // MARK: - Lookup by Action

    func testDefaultBindingStringForNewTab() {
        let manager = KeybindingsManager.shared
        let str = manager.defaultBindingString(for: .newTab)
        XCTAssertNotNil(str, "Should find a binding for newTab")
        // newTab is cmd+t, formatted as "Cmd+T"
        XCTAssertTrue(str?.contains("Cmd") ?? false, "newTab binding should contain Cmd")
        XCTAssertTrue(str?.contains("T") ?? false, "newTab binding should contain T")
    }

    func testDefaultBindingStringForCopy() {
        let manager = KeybindingsManager.shared
        let str = manager.defaultBindingString(for: .copy)
        XCTAssertNotNil(str)
        XCTAssertTrue(str?.contains("Cmd") ?? false)
        XCTAssertTrue(str?.contains("C") ?? false)
    }

    func testDefaultBindingStringForPaste() {
        let manager = KeybindingsManager.shared
        let str = manager.defaultBindingString(for: .paste)
        XCTAssertNotNil(str)
        XCTAssertTrue(str?.contains("Cmd") ?? false)
        XCTAssertTrue(str?.contains("V") ?? false)
    }

    func testDefaultBindingStringForUnboundAction() {
        let manager = KeybindingsManager.shared
        // selectTab1 is not in the default shortcuts
        let str = manager.defaultBindingString(for: .selectTab1)
        XCTAssertNil(str, "Actions not in default shortcuts should return nil")
    }

    // MARK: - Available Presets

    func testAvailablePresetsContainsDefault() {
        XCTAssertTrue(KeybindingsManager.availablePresets.contains("default"))
    }

    func testAvailablePresetsContainsVim() {
        XCTAssertTrue(KeybindingsManager.availablePresets.contains("vim"))
    }

    func testAvailablePresetsContainsEmacs() {
        XCTAssertTrue(KeybindingsManager.availablePresets.contains("emacs"))
    }

    // MARK: - KeyBinding.parse

    func testParseSimpleBinding() {
        let binding = KeyBinding.parse("cmd+c", action: .copy)
        XCTAssertNotNil(binding)
        XCTAssertEqual(binding?.key, "c")
        XCTAssertEqual(binding?.modifiers, .command)
        XCTAssertEqual(binding?.action, .copy)
    }

    func testParseMultipleModifiers() {
        let binding = KeyBinding.parse("cmd+shift+t", action: .newTab)
        XCTAssertNotNil(binding)
        XCTAssertEqual(binding?.key, "t")
        XCTAssertTrue(binding?.modifiers.contains(.command) ?? false)
        XCTAssertTrue(binding?.modifiers.contains(.shift) ?? false)
    }

    func testParseCtrlBinding() {
        let binding = KeyBinding.parse("ctrl+c", action: .interrupt)
        XCTAssertNotNil(binding)
        XCTAssertEqual(binding?.key, "c")
        XCTAssertEqual(binding?.modifiers, .control)
    }

    func testParseOptionBinding() {
        let binding = KeyBinding.parse("opt+v", action: .paste)
        XCTAssertNotNil(binding)
        XCTAssertEqual(binding?.key, "v")
        XCTAssertEqual(binding?.modifiers, .option)
    }

    func testParseAltIsOption() {
        let binding = KeyBinding.parse("alt+v", action: .paste)
        XCTAssertNotNil(binding)
        XCTAssertEqual(binding?.modifiers, .option,
            "alt should be parsed as option modifier")
    }

    func testParseCommandAlias() {
        let binding = KeyBinding.parse("command+c", action: .copy)
        XCTAssertNotNil(binding)
        XCTAssertEqual(binding?.modifiers, .command,
            "command should be parsed as command modifier")
    }

    func testParseControlAlias() {
        let binding = KeyBinding.parse("control+c", action: .interrupt)
        XCTAssertNotNil(binding)
        XCTAssertEqual(binding?.modifiers, .control)
    }

    func testParseOptionAlias() {
        let binding = KeyBinding.parse("option+v", action: .paste)
        XCTAssertNotNil(binding)
        XCTAssertEqual(binding?.modifiers, .option)
    }

    func testParseEmptyStringReturnsNil() {
        let binding = KeyBinding.parse("", action: .copy)
        XCTAssertNil(binding, "Empty string should return nil")
    }

    func testParseModifiersOnlyReturnsNil() {
        let binding = KeyBinding.parse("cmd+shift+", action: .copy)
        // Last component after split is empty, so keyString remains nil
        XCTAssertNil(binding,
            "Modifiers-only string (trailing +) should return nil since there is no key")
    }

    func testParseCaseInsensitive() {
        let binding = KeyBinding.parse("CMD+SHIFT+T", action: .newTab)
        XCTAssertNotNil(binding)
        XCTAssertEqual(binding?.key, "t", "Key should be lowercased")
        XCTAssertTrue(binding?.modifiers.contains(.command) ?? false)
        XCTAssertTrue(binding?.modifiers.contains(.shift) ?? false)
    }

    // MARK: - KeyBinding.modifiers(from:)

    func testModifiersFromParts() {
        let mods = KeyBinding.modifiers(from: ["cmd", "shift", "ctrl", "opt"])
        XCTAssertTrue(mods.contains(.command))
        XCTAssertTrue(mods.contains(.shift))
        XCTAssertTrue(mods.contains(.control))
        XCTAssertTrue(mods.contains(.option))
    }

    func testModifiersFromEmptyArray() {
        let mods = KeyBinding.modifiers(from: [])
        XCTAssertTrue(mods.isEmpty)
    }

    func testModifiersFromUnknownParts() {
        let mods = KeyBinding.modifiers(from: ["foo", "bar"])
        XCTAssertTrue(mods.isEmpty, "Unknown modifier strings should be ignored")
    }

    // MARK: - KeyAction

    func testKeyActionFromShortcutActionNewTab() {
        XCTAssertEqual(KeyAction.fromShortcutAction("newTab"), .newTab)
    }

    func testKeyActionFromShortcutActionCopy() {
        XCTAssertEqual(KeyAction.fromShortcutAction("copy"), .copy)
    }

    func testKeyActionFromShortcutActionPaste() {
        XCTAssertEqual(KeyAction.fromShortcutAction("paste"), .paste)
    }

    func testKeyActionFromShortcutActionFind() {
        XCTAssertEqual(KeyAction.fromShortcutAction("find"), .toggleSearch,
            "find should map to toggleSearch")
    }

    func testKeyActionFromShortcutActionFindNext() {
        XCTAssertEqual(KeyAction.fromShortcutAction("findNext"), .nextMatch)
    }

    func testKeyActionFromShortcutActionFindPrevious() {
        XCTAssertEqual(KeyAction.fromShortcutAction("findPrevious"), .previousMatch)
    }

    func testKeyActionFromShortcutActionUnknown() {
        XCTAssertNil(KeyAction.fromShortcutAction("nonExistentAction"),
            "Unknown action strings should return nil")
    }

    func testKeyActionFromShortcutActionSplitHorizontal() {
        XCTAssertEqual(KeyAction.fromShortcutAction("splitHorizontal"), .splitHorizontal)
    }

    func testKeyActionFromShortcutActionSplitVertical() {
        XCTAssertEqual(KeyAction.fromShortcutAction("splitVertical"), .splitVertical)
    }

    func testKeyActionFromShortcutActionOpenTextEditor() {
        XCTAssertEqual(KeyAction.fromShortcutAction("openTextEditor"), .openTextEditor)
    }

    // MARK: - KeyAction Display Names

    func testKeyActionDisplayNames() {
        // Verify all cases have non-empty display names
        for action in KeyAction.allCases {
            XCTAssertFalse(action.displayName.isEmpty,
                "KeyAction.\(action.rawValue) should have a non-empty displayName")
        }
    }

    // MARK: - KeyboardShortcut (from FeatureSettings.swift)

    func testKeyboardShortcutDisplayString() {
        let shortcut = KeyboardShortcut(action: "test", key: "t", modifiers: ["cmd"])
        XCTAssertEqual(shortcut.displayString, "\u{2318}T",
            "displayString should show cmd symbol and uppercase key")
    }

    func testKeyboardShortcutDisplayStringMultipleModifiers() {
        let shortcut = KeyboardShortcut(action: "test", key: "t", modifiers: ["ctrl", "opt", "shift", "cmd"])
        // Order: ctrl, opt, shift, cmd
        XCTAssertEqual(shortcut.displayString, "\u{2303}\u{2325}\u{21E7}\u{2318}T")
    }

    func testKeyboardShortcutDefaultShortcutsNotEmpty() {
        XCTAssertFalse(KeyboardShortcut.defaultShortcuts.isEmpty)
    }

    func testKeyboardShortcutIdentifiable() {
        let shortcut = KeyboardShortcut(action: "newTab", key: "t", modifiers: ["cmd"])
        XCTAssertEqual(shortcut.id, "newTab", "id should equal the action name")
    }

    func testKeyboardShortcutEquatable() {
        let a = KeyboardShortcut(action: "newTab", key: "t", modifiers: ["cmd"])
        let b = KeyboardShortcut(action: "newTab", key: "t", modifiers: ["cmd"])
        XCTAssertEqual(a, b)
    }

    func testKeyboardShortcutPresetsVim() {
        let vimShortcuts = KeyboardShortcut.shortcuts(for: "vim")
        XCTAssertFalse(vimShortcuts.isEmpty)
        let nextTab = vimShortcuts.first { $0.action == "nextTab" }
        XCTAssertNotNil(nextTab)
        XCTAssertEqual(nextTab?.key, "l")
        XCTAssertTrue(nextTab?.modifiers.contains("ctrl") ?? false)
    }

    func testKeyboardShortcutPresetsEmacs() {
        let emacsShortcuts = KeyboardShortcut.shortcuts(for: "emacs")
        XCTAssertFalse(emacsShortcuts.isEmpty)
        let nextTab = emacsShortcuts.first { $0.action == "nextTab" }
        XCTAssertNotNil(nextTab)
        XCTAssertEqual(nextTab?.key, "n")
        XCTAssertTrue(nextTab?.modifiers.contains("ctrl") ?? false)
    }

    func testKeyboardShortcutPresetsDefaultFallback() {
        let defaultShortcuts = KeyboardShortcut.shortcuts(for: "unknown_preset")
        XCTAssertEqual(defaultShortcuts, KeyboardShortcut.defaultShortcuts,
            "Unknown preset should fall back to default shortcuts")
    }

    func testKeyboardShortcutActionDisplayName() {
        XCTAssertEqual(KeyboardShortcut.actionDisplayName("newTab"), "New Tab")
        XCTAssertEqual(KeyboardShortcut.actionDisplayName("closeTab"), "Close Tab")
        XCTAssertEqual(KeyboardShortcut.actionDisplayName("copy"), "Copy")
        XCTAssertEqual(KeyboardShortcut.actionDisplayName("paste"), "Paste")
    }

    func testKeyboardShortcutActionDisplayNameUnknownReturnsRaw() {
        let unknown = "someUnknownAction"
        XCTAssertEqual(KeyboardShortcut.actionDisplayName(unknown), unknown,
            "Unknown action names should return the raw string")
    }
}

#endif
