import Chau7Core
import Foundation

/// Owns the notification settings domain end to end: loading, one-time
/// migrations, normalization, persistence, and the rate-limiter sync hook.
///
/// Extracted from `FeatureSettings`, which stays the facade — its
/// `notificationSettings` property forwards here, so the 90+ consumer files
/// are unchanged while the domain itself becomes independently testable.
@Observable
final class NotificationSettingsStore {

    enum Keys {
        static let notificationTriggerState = "notifications.triggerState"
        static let notificationMutedRepos = "notifications.mutedRepos"
        static let notificationPushTaskCompletions = "notifications.pushTaskCompletionsToiOS"
        static let notificationFilters = "notifications.filters"
        static let triggerActionBindings = "notifications.triggerActionBindings"
        static let notificationRateLimitConfig = "notifications.rateLimitConfig"
        static let triggerConditions = "notifications.triggerConditions"
        static let groupActionBindings = "notifications.groupActionBindings"
        static let groupConditions = "notifications.groupConditions"
    }

    @ObservationIgnored private var isUpdating = false
    @ObservationIgnored private let defaults: UserDefaults

    var settings: NotificationSettings {
        didSet {
            guard !isUpdating else { return }
            isUpdating = true
            defer { isUpdating = false }

            // Normalize trigger state
            settings.triggerState.normalize()
            // Sync legacy filters
            settings.filters = Self.legacyNotificationFilters(from: settings.triggerState)
            // Persist
            persist()
            // Sync rate limiter if config changed
            if settings.rateLimitConfig != oldValue.rateLimitConfig {
                let newConfig = settings.rateLimitConfig
                DispatchQueue.main.async { @MainActor in
                    // Route through the composition root rather than a
                    // direct singleton dereference. The slot is
                    // populated by AppModel.init at app startup; in
                    // tests that don't construct AppModel the rate
                    // limiter sync becomes a no-op.
                    if let services = NotificationServices.current {
                        services.manager.rateLimiter.config = newConfig
                        services.manager.rateLimiter.reset()
                    }
                }
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.settings = Self.loadAndMigrate(defaults: defaults)
    }

    // MARK: - Loading + one-time migrations

    private static func loadAndMigrate(defaults: UserDefaults) -> NotificationSettings {
        let loadedFilters: NotificationFilters
        if let data = defaults.data(forKey: Keys.notificationFilters),
           let filters = JSONOperations.decode(NotificationFilters.self, from: data, context: "notificationFilters") {
            loadedFilters = filters
        } else {
            loadedFilters = .defaults
        }

        let loadedMutedRepos = loadMutedRepos(from: defaults)
        let loadedPushTaskCompletions = defaults.object(forKey: Keys.notificationPushTaskCompletions) as? Bool ?? true

        let resolvedTriggerState: NotificationTriggerState
        if let data = defaults.data(forKey: Keys.notificationTriggerState),
           let state = JSONOperations.decode(NotificationTriggerState.self, from: data, context: "notificationTriggerState") {
            var normalized = state
            normalized.normalize()
            resolvedTriggerState = normalized
        } else {
            resolvedTriggerState = triggerState(from: loadedFilters)
        }

        var normalizedBindings = loadTriggerActionBindings(from: defaults)
        normalizedBindings = migrateFinishedColorDefault(normalizedBindings, defaults: defaults)
        normalizedBindings = migratePermissionPersistence(normalizedBindings, defaults: defaults)
        normalizedBindings = migrateFinishedPersistUntilOpen(normalizedBindings, defaults: defaults)

        let loadedRateLimitConfig: NotificationRateLimiter.Config
        if let data = defaults.data(forKey: Keys.notificationRateLimitConfig),
           let config = JSONOperations.decode(NotificationRateLimiter.Config.self, from: data, context: "notificationRateLimitConfig") {
            loadedRateLimitConfig = config
        } else {
            loadedRateLimitConfig = .default
        }

        let loadedConditions: [String: TriggerCondition]
        if let data = defaults.data(forKey: Keys.triggerConditions),
           let conditions = JSONOperations.decode([String: TriggerCondition].self, from: data, context: "triggerConditions") {
            loadedConditions = conditions
        } else {
            loadedConditions = [:]
        }

        let loadedGroupActionBindings: [String: [NotificationActionConfig]]
        if let data = defaults.data(forKey: Keys.groupActionBindings),
           let bindings = JSONOperations.decode([String: [NotificationActionConfig]].self, from: data, context: "groupActionBindings"),
           !bindings.isEmpty {
            loadedGroupActionBindings = bindings
        } else {
            loadedGroupActionBindings = NotificationSettings.defaultGroupActionBindings
        }
        let normalizedGroupActionBindings = normalizedAgentGroupActionBindings(loadedGroupActionBindings)

        let loadedGroupConditions: [String: TriggerCondition]
        if let data = defaults.data(forKey: Keys.groupConditions),
           let conditions = JSONOperations.decode([String: TriggerCondition].self, from: data, context: "groupConditions") {
            loadedGroupConditions = conditions
        } else {
            loadedGroupConditions = [:]
        }

        return NotificationSettings(
            triggerState: resolvedTriggerState,
            filters: legacyNotificationFilters(from: resolvedTriggerState),
            triggerActionBindings: normalizedBindings,
            rateLimitConfig: loadedRateLimitConfig,
            triggerConditions: loadedConditions,
            groupActionBindings: normalizedGroupActionBindings,
            groupConditions: loadedGroupConditions,
            mutedRepos: loadedMutedRepos,
            pushTaskCompletionsToiOS: loadedPushTaskCompletions
        )
    }

    static func loadTriggerActionBindings(from defaults: UserDefaults) -> [String: [NotificationActionConfig]] {
        let loaded: [String: [NotificationActionConfig]]
        if let data = defaults.data(forKey: Keys.triggerActionBindings),
           let bindings = JSONOperations.decode([String: [NotificationActionConfig]].self, from: data, context: "triggerActionBindings") {
            loaded = bindings
        } else {
            loaded = defaultTriggerActionBindings()
        }
        var normalized = loaded
        if normalized["claude_code.failed"] == nil {
            normalized["claude_code.failed"] = defaultTriggerActionBindings()["claude_code.failed"]
        }
        if normalized["codex.failed"] == nil {
            normalized["codex.failed"] = defaultTriggerActionBindings()["codex.failed"]
        }
        if normalized["claude_code.idle"] == nil {
            normalized["claude_code.idle"] = []
        }
        if normalized["codex.idle"] == nil {
            normalized["codex.idle"] = []
        }
        return normalized
    }

    static func loadMutedRepos(from defaults: UserDefaults) -> [String: RepoMute] {
        guard let data = defaults.data(forKey: Keys.notificationMutedRepos),
              let muted = JSONOperations.decode([String: RepoMute].self, from: data, context: "notificationMutedRepos") else {
            return [:]
        }
        return RepoNotificationMuting.pruned(muted)
    }

    /// One-time migration: the previous default for *.finished triggers
    /// painted a *red* border on completion, which conflicted with
    /// convention (red == error) and confused users who never set it.
    /// The new default is green. We migrate ONLY users who are still on
    /// the literal old default — anyone who customized to a different
    /// color (including red on purpose) keeps their setting.
    ///
    /// Gated by a one-shot UserDefaults flag (same pattern as
    /// `cto.migrated.v1`) so the detection loop runs at most once per
    /// install AND the migrated bindings are written back to UserDefaults
    /// eagerly (assigning `settings` inside `init` does not fire `didSet`,
    /// so the natural persistence path would never run for the migration
    /// alone).
    private static func migrateFinishedColorDefault(
        _ bindings: [String: [NotificationActionConfig]],
        defaults: UserDefaults
    ) -> [String: [NotificationActionConfig]] {
        let migrationKey = "notification.finished.greenDefault.v1"
        guard !defaults.bool(forKey: migrationKey) else { return bindings }
        var normalizedBindings = bindings
        var migrated = false
        for triggerKey in ["claude_code.finished", "codex.finished"] {
            guard var actions = normalizedBindings[triggerKey] else { continue }
            for index in actions.indices where actions[index].actionType == .styleTab {
                let cfg = actions[index].config
                guard cfg["style"] == "custom",
                      cfg["customColor"] == "red",
                      cfg["borderWidth"] == "2",
                      cfg["autoClearSeconds"] == "30" else { continue }
                var migratedCfg = cfg
                migratedCfg["customColor"] = "green"
                actions[index] = NotificationActionConfig(
                    actionType: .styleTab,
                    enabled: actions[index].enabled,
                    config: migratedCfg
                )
                migrated = true
                Log.info("FeatureSettings migration: \(triggerKey) styleTab color red → green (default flip)")
            }
            normalizedBindings[triggerKey] = actions
        }
        if migrated,
           let data = JSONOperations.encode(normalizedBindings, context: "triggerActionBindings.greenDefault.v1") {
            defaults.set(data, forKey: Keys.triggerActionBindings)
        }
        defaults.set(true, forKey: migrationKey)
        return normalizedBindings
    }

    /// One-time migration: permission / waiting-input / attention trigger
    /// defaults were originally non-persistent at the per-trigger layer,
    /// even though the newer group defaults intentionally keep them visible
    /// until the prompt is resolved. Because NotificationPipeline prefers
    /// per-trigger bindings over group bindings, users who never customized
    /// these triggers could still get "disappears on select" behavior.
    /// Migrate only the literal old default shape so intentional custom
    /// configurations remain untouched.
    private static func migratePermissionPersistence(
        _ bindings: [String: [NotificationActionConfig]],
        defaults: UserDefaults
    ) -> [String: [NotificationActionConfig]] {
        let migrationKey = "notification.permission.persistentDefault.v1"
        guard !defaults.bool(forKey: migrationKey) else { return bindings }
        var normalizedBindings = bindings
        var migrated = false
        let permissionTriggerKeys = [
            "claude_code.permission",
            "claude_code.waiting_input",
            "claude_code.attention_required",
            "codex.permission",
            "codex.waiting_input",
            "codex.attention_required"
        ]
        for triggerKey in permissionTriggerKeys {
            guard var actions = normalizedBindings[triggerKey] else { continue }
            for index in actions.indices where actions[index].actionType == .styleTab {
                let cfg = actions[index].config
                guard cfg["style"] == "attention",
                      cfg["customColor"] == "orange",
                      cfg["borderWidth"] == "2",
                      cfg["pulse"] == "true",
                      cfg["autoClearSeconds"] == "0",
                      cfg["persistent"] == nil else { continue }
                var migratedCfg = cfg
                migratedCfg["persistent"] = "true"
                actions[index] = NotificationActionConfig(
                    actionType: .styleTab,
                    enabled: actions[index].enabled,
                    config: migratedCfg
                )
                migrated = true
                Log.info("FeatureSettings migration: \(triggerKey) styleTab now persistent by default")
            }
            normalizedBindings[triggerKey] = actions
        }
        if migrated,
           let data = JSONOperations.encode(normalizedBindings, context: "triggerActionBindings.permissionPersistent.v1") {
            defaults.set(data, forKey: Keys.triggerActionBindings)
        }
        defaults.set(true, forKey: migrationKey)
        return normalizedBindings
    }

    /// One-time migration: the "finished" (task complete) tab highlight
    /// originally auto-cleared after 30s, so the green completion border
    /// vanished before the user returned to the tab. The intended behavior
    /// is to keep the highlight until the user actually opens the tab — a
    /// non-persistent style is already cleared on select, so dropping the
    /// auto-clear timer (autoClearSeconds -> 0) is all that's needed.
    /// Migrate only the literal old default shape so intentional custom
    /// configurations remain untouched.
    private static func migrateFinishedPersistUntilOpen(
        _ bindings: [String: [NotificationActionConfig]],
        defaults: UserDefaults
    ) -> [String: [NotificationActionConfig]] {
        let migrationKey = "notification.finished.persistUntilOpen.v1"
        guard !defaults.bool(forKey: migrationKey) else { return bindings }
        var normalizedBindings = bindings
        var migrated = false
        for triggerKey in ["claude_code.finished", "codex.finished"] {
            guard var actions = normalizedBindings[triggerKey] else { continue }
            for index in actions.indices where actions[index].actionType == .styleTab {
                let cfg = actions[index].config
                guard cfg["style"] == "custom",
                      cfg["customColor"] == "green",
                      cfg["borderWidth"] == "2",
                      cfg["autoClearSeconds"] == "30" else { continue }
                var migratedCfg = cfg
                migratedCfg["autoClearSeconds"] = "0"
                actions[index] = NotificationActionConfig(
                    actionType: .styleTab,
                    enabled: actions[index].enabled,
                    config: migratedCfg
                )
                migrated = true
                Log.info("FeatureSettings migration: \(triggerKey) styleTab now persists until the tab is opened")
            }
            normalizedBindings[triggerKey] = actions
        }
        if migrated,
           let data = JSONOperations.encode(normalizedBindings, context: "triggerActionBindings.finishedPersist.v1") {
            defaults.set(data, forKey: Keys.triggerActionBindings)
        }
        defaults.set(true, forKey: migrationKey)
        return normalizedBindings
    }

    // MARK: - Persistence

    private func persist() {
        let ns = settings
        if let data = JSONOperations.encode(ns.triggerState, context: "notificationTriggerState") {
            defaults.set(data, forKey: Keys.notificationTriggerState)
        }
        if let data = JSONOperations.encode(ns.mutedRepos, context: "notificationMutedRepos") {
            defaults.set(data, forKey: Keys.notificationMutedRepos)
        }
        defaults.set(ns.pushTaskCompletionsToiOS, forKey: Keys.notificationPushTaskCompletions)
        if let data = JSONOperations.encode(ns.filters, context: "notificationFilters") {
            defaults.set(data, forKey: Keys.notificationFilters)
        }
        if let data = JSONOperations.encode(ns.triggerActionBindings, context: "triggerActionBindings") {
            defaults.set(data, forKey: Keys.triggerActionBindings)
        }
        if let data = JSONOperations.encode(ns.rateLimitConfig, context: "notificationRateLimitConfig") {
            defaults.set(data, forKey: Keys.notificationRateLimitConfig)
        }
        if let data = JSONOperations.encode(ns.triggerConditions, context: "triggerConditions") {
            defaults.set(data, forKey: Keys.triggerConditions)
        }
        if let data = JSONOperations.encode(ns.groupActionBindings, context: "groupActionBindings") {
            defaults.set(data, forKey: Keys.groupActionBindings)
        }
        if let data = JSONOperations.encode(ns.groupConditions, context: "groupConditions") {
            defaults.set(data, forKey: Keys.groupConditions)
        }
    }

    // MARK: - Legacy filter bridge

    static func triggerState(from filters: NotificationFilters) -> NotificationTriggerState {
        var state = NotificationTriggerState()
        for trigger in NotificationTriggerCatalog.all {
            switch trigger.type {
            case "finished":
                state.setEnabled(filters.taskFinished, for: trigger)
            case "waiting_input", "attention_required":
                state.setEnabled(filters.permissionRequest, for: trigger)
            case "failed":
                state.setEnabled(filters.taskFailed, for: trigger)
            case "needs_validation":
                state.setEnabled(filters.needsValidation, for: trigger)
            case "permission":
                state.setEnabled(filters.permissionRequest, for: trigger)
            case "tool_complete":
                state.setEnabled(filters.toolComplete, for: trigger)
            case "session_end":
                state.setEnabled(filters.sessionEnd, for: trigger)
            case "idle":
                state.setEnabled(filters.commandIdle, for: trigger)
            default:
                continue
            }
        }
        return state
    }

    static func legacyNotificationFilters(from state: NotificationTriggerState) -> NotificationFilters {
        func anyEnabled(_ type: String) -> Bool {
            let triggers = NotificationTriggerCatalog.all.filter { $0.type == type && !$0.isWildcard }
            guard !triggers.isEmpty else { return true }
            return triggers.contains { state.isEnabled(for: $0) }
        }

        return NotificationFilters(
            taskFinished: anyEnabled("finished"),
            taskFailed: anyEnabled("failed"),
            needsValidation: anyEnabled("needs_validation"),
            permissionRequest: anyEnabled("permission") || anyEnabled("waiting_input") || anyEnabled("attention_required"),
            toolComplete: anyEnabled("tool_complete"),
            sessionEnd: anyEnabled("session_end"),
            commandIdle: anyEnabled("idle")
        )
    }

    // MARK: - Defaults + backfills

    /// Default trigger-action bindings for AI agent notifications.
    /// Sets up: desk notification, chime, dock bounce, and red tab border for finished/permission triggers.
    static func defaultTriggerActionBindings() -> [String: [NotificationActionConfig]] {
        // Actions for "finished" triggers (task complete)
        let finishedActions: [NotificationActionConfig] = [
            NotificationActionConfig(actionType: .showNotification, enabled: true, config: [:]),
            NotificationActionConfig(actionType: .playSound, enabled: true, config: ["sound": "Glass", "volume": "80"]),
            NotificationActionConfig(actionType: .dockBounce, enabled: true, config: ["critical": "false"]),
            NotificationActionConfig(actionType: .styleTab, enabled: true, config: [
                "style": "custom",
                "customColor": "green",
                "borderWidth": "2",
                "autoClearSeconds": "0"
            ])
        ]

        // Actions for "failed" triggers (task failed / errored)
        let failedActions: [NotificationActionConfig] = [
            NotificationActionConfig(actionType: .showNotification, enabled: true, config: [:]),
            NotificationActionConfig(actionType: .playSound, enabled: true, config: ["sound": "Basso", "volume": "80"]),
            NotificationActionConfig(actionType: .dockBounce, enabled: true, config: ["critical": "false"]),
            NotificationActionConfig(actionType: .styleTab, enabled: true, config: [
                "style": "error",
                "autoClearSeconds": "60"
            ])
        ]

        // Actions for "permission" triggers (needs user input)
        let permissionActions: [NotificationActionConfig] = [
            NotificationActionConfig(actionType: .showNotification, enabled: true, config: [:]),
            NotificationActionConfig(actionType: .playSound, enabled: true, config: ["sound": "Purr", "volume": "80"]),
            NotificationActionConfig(actionType: .dockBounce, enabled: true, config: ["critical": "true"]),
            NotificationActionConfig(actionType: .styleTab, enabled: true, config: [
                "style": "attention",
                "customColor": "orange",
                "borderWidth": "2",
                "pulse": "true",
                "autoClearSeconds": "0",
                "persistent": "true"
            ])
        ]

        // Actions for "idle" triggers (session may be waiting, but no permission-specific styling)
        let idleActions: [NotificationActionConfig] = []

        // Actions for file conflict alerts
        let conflictActions: [NotificationActionConfig] = [
            NotificationActionConfig(actionType: .showNotification, enabled: true, config: [:]),
            NotificationActionConfig(actionType: .playSound, enabled: true, config: ["sound": "Basso", "volume": "60"]),
            NotificationActionConfig(actionType: .styleTab, enabled: true, config: [
                "style": "custom",
                "customColor": "orange",
                "borderWidth": "2",
                "autoClearSeconds": "60"
            ])
        ]

        return [
            // Claude Code triggers
            "claude_code.finished": finishedActions,
            "claude_code.failed": failedActions,
            "claude_code.permission": permissionActions,
            "claude_code.waiting_input": permissionActions,
            "claude_code.attention_required": permissionActions,
            "claude_code.idle": idleActions,
            // Codex triggers
            "codex.finished": finishedActions,
            "codex.failed": failedActions,
            "codex.permission": permissionActions,
            "codex.waiting_input": permissionActions,
            "codex.attention_required": permissionActions,
            "codex.idle": idleActions,
            // App triggers
            "app.file_conflict": conflictActions
        ]
    }

    /// Backfill the agent finished / approval / feedback group bindings — and the
    /// dock bounce within them — for installs whose bindings were persisted before
    /// these became defaults. A key that is entirely absent is seeded from the
    /// catalog default; a binding that exists but carries no `dockBounce` action at
    /// all gains one. A *disabled* dock bounce is left untouched: the settings UI
    /// keeps the action present-but-off, so its absence (not its disabled state)
    /// marks the older default.
    static func normalizedAgentGroupActionBindings(
        _ loaded: [String: [NotificationActionConfig]]
    ) -> [String: [NotificationActionConfig]] {
        let agentKeys = [
            "ai_coding.finished", "ai_coding.failed", "ai_coding.permission",
            "ai_coding.waiting_input", "ai_coding.attention_required",
            "ai_coding.elicitation", "ai_coding.response_failed"
        ]
        var result = loaded
        if result["ai_coding.idle"] == nil {
            result["ai_coding.idle"] = []
        }
        for key in agentKeys {
            guard let defaultBinding = NotificationSettings.defaultGroupActionBindings[key] else { continue }
            guard var existing = result[key], !existing.isEmpty else {
                result[key] = defaultBinding
                continue
            }
            guard !existing.contains(where: { $0.actionType == .dockBounce }),
                  let defaultBounce = defaultBinding.first(where: { $0.actionType == .dockBounce })
            else { continue }
            let insertAt = existing.firstIndex(where: { $0.actionType == .showNotification }).map { $0 + 1 } ?? 0
            existing.insert(defaultBounce, at: insertAt)
            result[key] = existing
        }
        return result
    }
}
