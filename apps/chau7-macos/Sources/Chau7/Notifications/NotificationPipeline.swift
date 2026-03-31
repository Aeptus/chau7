import Foundation
import Chau7Core

/// Pure decision engine for the notification system.
/// Takes event + all state as input, returns what should happen — no side effects.
/// Rate limiting is intentionally excluded (it has mutable state) and applied by the caller.
enum NotificationPipeline {

    enum Decision: Equatable {
        /// Don't fire — trigger disabled or condition not met
        case drop(reason: String)
        /// Fire the default notification (native or AppleScript path)
        case fireDefault(triggerId: String?)
        /// Suppress the intrusive notification path but still style the tab.
        case fireStyleOnly(triggerId: String?, actions: [NotificationActionConfig])
        /// Fire specific configured actions
        case fireActions(triggerId: String, actions: [NotificationActionConfig])
    }

    struct Input {
        let event: AIEvent
        let triggerState: NotificationTriggerState
        let triggerConditions: [String: TriggerCondition]
        let actionBindings: [String: [NotificationActionConfig]]
        let groupConditions: [String: TriggerCondition]
        let groupActionBindings: [String: [NotificationActionConfig]]
        let isFocusModeActive: Bool
        let isAppActive: Bool
        let isToolTabActive: Bool
    }

    /// Resolve a group trigger ID for the given trigger, if it belongs to a group.
    private static func groupTriggerId(for trigger: NotificationTrigger) -> String? {
        guard let group = NotificationTriggerCatalog.group(for: trigger.source) else { return nil }
        return group.groupTriggerId(for: trigger.type)
    }

    private static func resolvedCondition(for trigger: NotificationTrigger, input: Input) -> TriggerCondition {
        if let perTrigger = input.triggerConditions[trigger.id] {
            return perTrigger
        }
        if let gid = groupTriggerId(for: trigger),
           let groupCondition = input.groupConditions[gid] {
            return groupCondition
        }
        return .default
    }

    private static func resolvedActions(for trigger: NotificationTrigger, input: Input) -> [NotificationActionConfig] {
        if let bound = input.actionBindings[trigger.id], !bound.isEmpty {
            return bound
        }
        if let gid = groupTriggerId(for: trigger),
           let groupActions = input.groupActionBindings[gid], !groupActions.isEmpty {
            return groupActions
        }
        return [NotificationActionConfig(actionType: .showNotification, enabled: true)]
    }

    static func evaluate(_ input: Input) -> Decision {
        // 1. Find matching trigger (O(1) via catalog index)
        let trigger = NotificationTriggerCatalog.trigger(for: input.event)

        // 2. Check if trigger is enabled (3-tier via NotificationTriggerState)
        if let trigger {
            guard input.triggerState.isEnabled(for: trigger) else {
                return .drop(reason: "Trigger \(trigger.id) disabled")
            }
        }

        // 3. Evaluate trigger conditions (3-tier: per-trigger → group → default)
        if let trigger {
            let condition = resolvedCondition(for: trigger, input: input)
            if condition.respectDND, input.isFocusModeActive {
                return .drop(reason: "DND/Focus active")
            }
            if condition.onlyWhenUnfocused, input.isAppActive {
                return .drop(reason: "App is active (onlyWhenUnfocused)")
            }
            let actions = resolvedActions(for: trigger, input: input)

            // 4a. If every resolved action is disabled, nothing should execute.
            guard actions.contains(where: \.enabled) else {
                return .drop(reason: "All actions disabled for trigger \(trigger.id)")
            }

            if condition.onlyWhenTabInactive, input.isToolTabActive {
                let styleActions = NotificationStylePlanner.styleOnlyActions(
                    for: input.event,
                    from: actions
                )
                if !styleActions.isEmpty {
                    return .fireStyleOnly(triggerId: trigger.id, actions: styleActions)
                }
                return .drop(reason: "Tool tab is active (onlyWhenTabInactive)")
            }

            // 5. Optimize: single default showNotification → use native path
            if actions.count == 1,
               let first = actions.first,
               first.enabled,
               first.actionType == .showNotification,
               first.config.isEmpty {
                return .fireDefault(triggerId: trigger.id)
            }

            return .fireActions(triggerId: trigger.id, actions: actions)
        }

        // 4b. No matching trigger → apply full default conditions, then use default notification
        guard trigger == nil else {
            return .drop(reason: "Unexpected matched trigger state")
        }
        let defaults = TriggerCondition.default
        if defaults.respectDND, input.isFocusModeActive {
            return .drop(reason: "DND/Focus active (unmatched trigger, default condition)")
        }
        if defaults.onlyWhenUnfocused, input.isAppActive {
            return .drop(reason: "App is active (unmatched trigger, default condition)")
        }
        if defaults.onlyWhenTabInactive, input.isToolTabActive {
            let styleActions = NotificationStylePlanner.styleOnlyActions(
                for: input.event,
                from: []
            )
            if !styleActions.isEmpty {
                return .fireStyleOnly(triggerId: nil, actions: styleActions)
            }
            return .drop(reason: "Tool tab is active (unmatched trigger, default condition)")
        }
        return .fireDefault(triggerId: nil)
    }
}
