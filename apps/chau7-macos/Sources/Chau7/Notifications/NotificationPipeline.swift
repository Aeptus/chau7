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
            let condition: TriggerCondition
            if let perTrigger = input.triggerConditions[trigger.id] {
                condition = perTrigger
            } else if let gid = groupTriggerId(for: trigger),
                      let groupCondition = input.groupConditions[gid] {
                condition = groupCondition
            } else {
                condition = .default
            }
            if condition.respectDND, input.isFocusModeActive {
                return .drop(reason: "DND/Focus active")
            }
            if condition.onlyWhenUnfocused, input.isAppActive {
                return .drop(reason: "App is active (onlyWhenUnfocused)")
            }
            if condition.onlyWhenTabInactive, input.isToolTabActive {
                return .drop(reason: "Tool tab is active (onlyWhenTabInactive)")
            }
        }

        // 4. No matching trigger → apply full default conditions, then use default notification
        guard let trigger else {
            let defaults = TriggerCondition.default
            if defaults.respectDND, input.isFocusModeActive {
                return .drop(reason: "DND/Focus active (unmatched trigger, default condition)")
            }
            if defaults.onlyWhenUnfocused, input.isAppActive {
                return .drop(reason: "App is active (unmatched trigger, default condition)")
            }
            if defaults.onlyWhenTabInactive, input.isToolTabActive {
                return .drop(reason: "Tool tab is active (unmatched trigger, default condition)")
            }
            return .fireDefault(triggerId: nil)
        }

        // 5. Resolve actions (3-tier: per-trigger → group → default)
        let actions: [NotificationActionConfig]
        if let bound = input.actionBindings[trigger.id], !bound.isEmpty {
            actions = bound
        } else if let gid = groupTriggerId(for: trigger),
                  let groupActions = input.groupActionBindings[gid], !groupActions.isEmpty {
            actions = groupActions
        } else {
            actions = [NotificationActionConfig(actionType: .showNotification, enabled: true)]
        }

        // 6a. If every resolved action is disabled, nothing should execute.
        guard actions.contains(where: \.enabled) else {
            return .drop(reason: "All actions disabled for trigger \(trigger.id)")
        }

        // 6. Optimize: single default showNotification → use native path
        if actions.count == 1,
           let first = actions.first,
           first.enabled,
           first.actionType == .showNotification,
           first.config.isEmpty {
            return .fireDefault(triggerId: trigger.id)
        }

        return .fireActions(triggerId: trigger.id, actions: actions)
    }
}
