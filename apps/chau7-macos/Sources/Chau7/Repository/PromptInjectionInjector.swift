import Foundation
import Chau7Core

/// Local (TUI-side) prompt injection.
///
/// Mirrors the proxy's `inject.go` injector but operates on the terminal-input
/// path: when a matching event fires for an active AI tool, paste the rule's
/// content into the TUI input field via bracketed paste. Submission is left
/// to the user — we never press Enter for them.
///
/// Why this exists in addition to the proxy injector:
///   the proxy can only mutate request bodies it parses. Codex with ChatGPT
///   subscription auth uses WebSocket transport; the proxy tunnels those
///   frames opaquely (`proxy.go:52-59`), so proxy-side injection silently
///   no-ops. Terminal-input injection is auth- and transport-agnostic.
///
/// Trigger coverage on this path:
///   - `firstSessionPrompt` ✓ (fires on AI-tool-detected, once per shell launch)
///   - `afterCompact`       ✓ (fires after `/compact` is submitted)
///   - `afterClear`         ✓ (fires after `/clear` is submitted)
///   - `everyPrompt`        ✗ (out of scope; the TUI doesn't expose a per-
///                              keystroke "user is about to submit" signal)
enum PromptInjectionInjector {
    /// Per-shell-launch dedup state for `firstSessionPrompt`.
    /// Key: "<proxyCorrelationSessionID>|<ruleKey>".
    private static var firstFireSeen: Set<String> = []
    private static let stateQueue = DispatchQueue(label: "com.chau7.injector.tui.state")

    /// Delay between AI-tool detection and paste so the TUI has time to render
    /// its input box. Codex/Claude TUIs typically draw within ~200 ms; we use
    /// a generous margin since pasting before the input is ready drops bytes.
    private static let postDetectionDelayMs = 600

    /// Delay between `/compact` or `/clear` submission and paste so the TUI
    /// has time to process the slash command and clear its input field. If we
    /// paste too soon, our content gets concatenated to the user's `/clear`
    /// command rather than landing in a fresh empty input.
    private static let postSlashCommandDelayMs = 350

    // MARK: - Entry points

    /// Called when the live-agent process (Codex/Claude/Gemini/...) is first
    /// detected in a tab's process tree. May fire `firstSessionPrompt` rules.
    @MainActor
    static func onAIToolDetected(session: TerminalSessionModel) {
        scheduleFire(for: session, after: postDetectionDelayMs, event: .aiToolDetected)
    }

    /// Called when the user submits `/compact` or `/clear` in an active AI tab.
    @MainActor
    static func onSessionEvent(_ event: PromptInjectionSessionEvent, session: TerminalSessionModel) {
        let triggerEvent: TriggerEvent
        switch event {
        case .afterCompact: triggerEvent = .userCompacted
        case .afterClear: triggerEvent = .userCleared
        }
        scheduleFire(for: session, after: postSlashCommandDelayMs, event: triggerEvent)
    }

    // MARK: - Trigger gate (the meaningful policy decision)

    enum TriggerEvent {
        case aiToolDetected
        case userCompacted
        case userCleared
    }

    /// Decides whether `rule` should inject right now given `event` and the
    /// per-shell-launch memory of prior firings.
    ///
    /// Trade-offs to consider when implementing:
    ///   - `firstSessionPrompt`: should fire exactly once per (sessionID, rule)
    ///     so a fresh shell launch re-injects but a tab redraw doesn't.
    ///     Use `recordFirstFire` to mark it consumed before returning true.
    ///     The `aiToolDetected` event is the natural fit — that's "first AI
    ///     prompt opportunity in this shell launch."
    ///   - `afterCompact` / `afterClear`: fire every time the user types the
    ///     command. No dedup — the user explicitly asked for the reset.
    ///     Match `userCompacted` / `userCleared` events respectively.
    ///   - `everyPrompt`: out of scope here. Either ignore silently, or log
    ///     once per (rule, sessionID) so the user sees why nothing happened.
    ///   - A rule may have multiple triggers; this gate fires if ANY of them
    ///     match the event.
    ///
    /// Return `true` to inject. The rule's content will then be pasted into
    /// the TUI input field (no auto-submit).
    private static func shouldFire(
        rule: InjectionRuleStore.Rule,
        event: TriggerEvent,
        sessionID: String
    ) -> Bool {
        // TODO(option-b): implement the trigger policy. ~5–10 lines.
        // See the trade-offs in the doc comment above.
        return false
    }

    // MARK: - Dedup state

    private static func hasFired(rule: InjectionRuleStore.Rule, sessionID: String) -> Bool {
        let key = dedupKey(rule: rule, sessionID: sessionID)
        return stateQueue.sync { firstFireSeen.contains(key) }
    }

    private static func recordFirstFire(rule: InjectionRuleStore.Rule, sessionID: String) {
        let key = dedupKey(rule: rule, sessionID: sessionID)
        stateQueue.sync { _ = firstFireSeen.insert(key) }
    }

    private static func dedupKey(rule: InjectionRuleStore.Rule, sessionID: String) -> String {
        "\(sessionID)|\(ruleKey(rule))"
    }

    // MARK: - Internal: scheduling, lookup, send

    @MainActor
    private static func scheduleFire(
        for session: TerminalSessionModel,
        after delayMs: Int,
        event: TriggerEvent
    ) {
        let cwd = session.currentDirectory
        let sessionID = session.proxyCorrelationSessionID

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak session] in
            guard let session else { return }
            guard let rule = matchingRule(forCwd: cwd) else {
                Log.info("PromptInjectionInjector: no matching rule for cwd=\(cwd) (event=\(event))")
                return
            }
            guard shouldFire(rule: rule, event: event, sessionID: sessionID) else {
                Log.info("PromptInjectionInjector: rule \(ruleKey(rule)) skipped for event=\(event)")
                return
            }

            session.injectPromptContent(rule.content, position: rule.position)

            if rule.triggers.contains(.firstSessionPrompt), event == .aiToolDetected {
                recordFirstFire(rule: rule, sessionID: sessionID)
            }

            Log.info("PromptInjectionInjector: fired rule=\(ruleKey(rule)) cwd=\(cwd) event=\(event) bytes=\(rule.content.utf8.count)")
        }
    }

    /// Finds the most specific rule matching `cwd`. Mirrors `inject.go:matchRepository`.
    @MainActor
    private static func matchingRule(forCwd cwd: String) -> InjectionRuleStore.Rule? {
        let store = InjectionRuleStore.shared
        if let local = store.localRules[cwd] {
            return local
        }
        return store.rules.first { matches(pattern: $0.repository, cwd: cwd) }
    }

    private static func matches(pattern: String, cwd: String) -> Bool {
        if pattern == "*" { return true }
        if pattern.hasPrefix("/") {
            if pattern == cwd { return true }
            if pattern.hasSuffix("/*") {
                let prefix = String(pattern.dropLast(2))
                return cwd.hasPrefix(prefix + "/")
            }
            return false
        }
        let basename = (cwd as NSString).lastPathComponent
        return pattern == basename
    }

    private static func ruleKey(_ rule: InjectionRuleStore.Rule) -> String {
        "\(rule.repository)|\(rule.position.rawValue)"
    }
}
