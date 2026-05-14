import Chau7Core
import Foundation
import SwiftUI

/// Three related notification-adjacent areas on `OverlayTabsModel`,
/// bundled because each builds on the previous:
///
///   1. **CTO (Token Optimization) per-tab control** — user toggles
///      the token-optimization override on a tab, which affects which
///      CTO flag file is written and is inspected by the shell wrapper.
///   2. **Tab notification styling** — applies/clears visual styles
///      (badges, border, tint, pulse) on tabs in response to
///      notification events. Used by both per-tab setters and the
///      programmatic `applyNotificationStyle(to:stylePreset:config:)`
///      from MCP / scripting actions.
///   3. **Notification action handlers** — the programmatic surface
///      that MCP / script actions call to focus a tab, set a badge,
///      insert a snippet, or query whether the event's tab is the
///      selected one.
extension OverlayTabsModel {

    // MARK: - Token Optimization (CTO) Per-Tab Control

    /// Toggles the token optimization override for a tab.
    /// Cycling depends on the global mode:
    /// - `allTabs`: default (on) -> forceOff -> default (on)
    /// - `aiOnly`: default -> forceOff -> forceOn -> default
    /// - `manual`: default (off) -> forceOn -> default (off)
    func toggleTokenOpt(for tabID: UUID) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }

        let mode = FeatureSettings.shared.tokenOptimizationMode
        guard mode != .off else { return }

        let current = tabs[index].tokenOptOverride
        let next: TabTokenOptOverride
        switch mode {
        case .off:
            return // Guarded above, but required for exhaustive switch
        case .allTabs:
            // Toggle: default (on) <-> forceOff
            next = (current == .default) ? .forceOff : .default
        case .aiOnly:
            // 3-state cycle: default -> forceOff -> forceOn -> default
            switch current {
            case .default: next = .forceOff
            case .forceOff: next = .forceOn
            case .forceOn: next = .default
            }
        case .manual:
            // Toggle: default (off) <-> forceOn
            next = (current == .default) ? .forceOn : .default
        }

        tabs[index].tokenOptOverride = next

        // Sync override to session so activeAppName.didSet can access it
        tabs[index].session?.tokenOptOverride = next

        // Recalculate flag file for this tab's session
        if let sessionID = tabs[index].session?.tabIdentifier {
            let isAI = tabs[index].session?.activeAppName != nil
            let decision = CTOFlagManager.recalculate(
                sessionID: sessionID,
                mode: mode,
                override: next,
                isAIActive: isAI
            )

            CTORuntimeMonitor.shared.recordDecision(
                sessionID: sessionID,
                mode: mode,
                override: next,
                isAIActive: isAI,
                previousState: decision.previousState,
                nextState: decision.nextState,
                changed: decision.changed,
                reason: decisionReason(
                    mode: mode,
                    override: next,
                    isAIActive: isAI
                ),
                trigger: .overrideChanged
            )
        }

        Log.info("CTO toggle: tab \(tabID) override changed to \(next.rawValue)")
    }

    /// Recalculates CTO flag files for all open tabs.
    /// Called when the global mode changes.
    func recalculateAllCTOFlags() {
        let mode = FeatureSettings.shared.tokenOptimizationMode
        if mode == .off {
            let removed = CTOFlagManager.removeAllFlags()
            CTORuntimeMonitor.shared.recordManagerBulkRemove(count: removed)
            return
        }

        for tab in tabs {
            guard let sessionID = tab.session?.tabIdentifier else { continue }
            guard let session = tab.session, !session.ctoFlagDeferred else {
                if let session = tab.session {
                    // Mode flip while the session was still deferred:
                    // the pending defer-flush will never resolve, so
                    // record it as a cancel (denominator-reducing) rather
                    // than a skip (denominator-preserving). A skip is for
                    // "a non-deferred decision interleaved while a defer
                    // was still pending"; this path is the defer itself
                    // being abandoned.
                    CTORuntimeMonitor.shared.recordDeferredCancel(
                        sessionID: session.tabIdentifier,
                        reason: "mode-change-before-first-prompt",
                        mode: mode,
                        override: tab.tokenOptOverride,
                        isAIActive: tab.session?.activeAppName != nil
                    )
                }
                continue
            }
            let isAI = tab.session?.activeAppName != nil
            let decision = CTOFlagManager.recalculate(
                sessionID: sessionID,
                mode: mode,
                override: tab.tokenOptOverride,
                isAIActive: isAI
            )
            CTORuntimeMonitor.shared.recordDecision(
                sessionID: sessionID,
                mode: mode,
                override: tab.tokenOptOverride,
                isAIActive: isAI,
                previousState: decision.previousState,
                nextState: decision.nextState,
                changed: decision.changed,
                reason: decisionReason(
                    mode: mode,
                    override: tab.tokenOptOverride,
                    isAIActive: isAI
                ),
                trigger: .modeChanged
            )
        }
    }

    // MARK: - Tab Notification Styling

    /// Sets a notification style on a tab to indicate a state (waiting, error, etc.)
    /// - Parameters:
    ///   - style: The style to apply, or nil to clear
    ///   - tabID: The tab to style (defaults to selected tab)
    /// - Returns: `true` when the style state actually changed and was published.
    @discardableResult
    func setNotificationStyle(_ style: TabNotificationStyle?, for tabID: UUID? = nil) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        let targetID = tabID ?? selectedTabID
        guard let index = tabs.firstIndex(where: { $0.id == targetID }) else { return false }

        if tabs[index].notificationStyle == style {
            if style == nil, tabs[index].stateAttentionKind != .none {
                tabs[index].stateAttentionKind = .none
                Log.info("Tab state attention ownership cleared for tab \(targetID)")
                return true
            }
            return false
        }

        if tabs[index].stateAttentionKind != .none {
            tabs[index].stateAttentionKind = .none
        }
        tabs[index].notificationStyle = style
        if let style {
            let desc = style.icon ?? "border/color"
            Log.info("Tab notification style set: \(desc) for tab \(targetID)")
        } else {
            Log.info("Tab notification style cleared for tab \(targetID)")
        }
        return true
    }

    /// Sets a notification style on the tab associated with a terminal session
    func setNotificationStyle(_ style: TabNotificationStyle?, forSession session: TerminalSessionModel) {
        guard let tab = tabs.first(where: { tab in
            tab.splitController.terminalSessions.contains { _, candidate in candidate === session }
        }) else { return }
        _ = setNotificationStyle(style, for: tab.id)
    }

    /// Clears persistent notification style (e.g., permission red border) when
    /// the session resumes after a permission answer.
    func clearPersistentStyle(for tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
              tabs[index].notificationStyle?.persistent == true else { return }
        tabs[index].notificationStyle = nil
        tabs[index].stateAttentionKind = .none
        Log.info("Persistent tab style cleared for tab \(tabID) (permission resolved)")
    }

    @discardableResult
    func clearPersistentNotificationStyle(on tabID: UUID) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
              tabs[index].notificationStyle?.persistent == true else { return false }
        clearPersistentStyle(for: tabID)
        return true
    }

    /// Clears notification style from a tab
    func clearNotificationStyle(for tabID: UUID? = nil) {
        setNotificationStyle(nil, for: tabID)
    }

    @discardableResult
    func applyNotificationStyle(to tabID: UUID, stylePreset: String, config: [String: String]) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))

        guard tabs.contains(where: { $0.id == tabID }) else {
            return false
        }

        let style: TabNotificationStyle? = stylePreset == "clear"
            ? nil
            : buildNotificationStyle(preset: stylePreset, config: config)

        return setNotificationStyle(style, for: tabID)
    }

    /// Builds a TabNotificationStyle from preset and config
    func buildNotificationStyle(preset: String, config: [String: String]) -> TabNotificationStyle {
        // Start with preset
        var style: TabNotificationStyle
        switch preset {
        case "waiting":
            style = .waiting
        case "error":
            style = .error
        case "success":
            style = .success
        case "attention":
            style = .attention
        case "custom":
            // Explicit custom: start blank, all fields come from config overrides below
            style = TabNotificationStyle()
        default:
            style = TabNotificationStyle()
        }

        // Apply custom overrides from config
        if let customColor = config["customColor"], !customColor.isEmpty {
            style.titleColor = colorFromString(customColor)
            style.iconColor = colorFromString(customColor)
        }

        // Allow explicit enable/disable of style features
        if let italic = config["italic"]?.lowercased() {
            style.isItalic = (italic == "true" || italic == "1")
        }

        if let bold = config["bold"]?.lowercased() {
            style.isBold = (bold == "true" || bold == "1")
        }

        if let pulse = config["pulse"]?.lowercased() {
            style.shouldPulse = (pulse == "true" || pulse == "1")
        }

        // Border configuration
        if let borderWidthStr = config["borderWidth"],
           let borderWidthDouble = Double(borderWidthStr),
           borderWidthDouble > 0 {
            style.borderWidth = CGFloat(borderWidthDouble)
            // Use customColor for border if specified, otherwise use titleColor
            if let customColor = config["customColor"], !customColor.isEmpty {
                style.borderColor = colorFromString(customColor)
            } else if let titleColor = style.titleColor {
                style.borderColor = titleColor
            } else {
                style.borderColor = .red // Default border color
            }
            // Border dash pattern
            switch config["borderStyle"]?.lowercased() {
            case "dotted":
                style.borderDash = [3, 3]
            case "dashed":
                style.borderDash = [6, 4]
            default:
                break // solid — nil dash
            }
        }

        if let persistentStr = config["persistent"]?.lowercased() {
            style.persistent = (persistentStr == "true" || persistentStr == "1")
        }

        return style
    }

    /// Converts color string to SwiftUI Color
    func colorFromString(_ colorName: String) -> Color {
        switch colorName.lowercased() {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "blue": return .blue
        case "purple": return .purple
        case "pink": return .pink
        default: return .primary
        }
    }

    // MARK: - Notification Action Handlers

    /// Resolve a tab from a target, preferring the pre-resolved tabID to avoid
    /// redundant TabResolver calls. Falls back to full resolution if no tabID.
    func resolveTab(for target: TabTarget) -> OverlayTab? {
        if let tabID = target.tabID {
            return tabs.first(where: { $0.id == tabID })
        }
        return TabResolver.resolve(target, in: tabs)
    }

    /// Finds the tab matching the target and selects it.
    @discardableResult
    func focusTab(id tabID: UUID) -> Bool {
        guard tabs.contains(where: { $0.id == tabID }) else {
            return false
        }
        selectTab(id: tabID)
        return true
    }

    func focusTab(for target: TabTarget) {
        guard let tab = resolveTab(for: target) else {
            Log.info("focusTab: No tab found for '\(target.tool)'")
            return
        }
        _ = focusTab(id: tab.id)
    }

    @discardableResult
    func setBadge(on tabID: UUID, text: String, color: String) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabID }) else {
            return false
        }
        var style = tab.notificationStyle ?? TabNotificationStyle()
        style.badgeText = text
        style.badgeColor = colorFromString(color)
        return setNotificationStyle(style, for: tabID)
    }

    @discardableResult
    func insertSnippet(id snippetId: String, on tabID: UUID, autoExecute: Bool) -> Bool {
        guard let entry = SnippetManager.shared.entries.first(where: { $0.snippet.id == snippetId }) else {
            Log.warn("insertSnippet: Snippet '\(snippetId)' not found")
            return false
        }
        guard tabs.contains(where: { $0.id == tabID }) else {
            return false
        }
        _ = focusTab(id: tabID)
        insertSnippet(entry)
        Log.info("insertSnippet: Inserted snippet '\(snippetId)' for tab \(tabID)")
        return true
    }

    /// Returns true if the given target matches the currently selected tab.
    func isToolInSelectedTab(_ target: TabTarget) -> Bool {
        // Only suppress notifications when we CONFIDENTLY know the event's tab
        // is the selected tab. Without a tabID, the resolver's best guess could
        // match the selected tab simply because it's the most active — which would
        // suppress ALL notifications when Chau7 is focused.
        guard let tabID = target.tabID else { return false }
        return tabID == selectedTabID
    }
}
