import Foundation
import Chau7Core

/// Maps every `NotificationActionType` to the handler that implements
/// it. Built once at executor construction; `NotificationActionExecutor`
/// asks the registry for a handler instead of running a 24-case switch.
///
/// Adding a new action becomes additive: write the handler type,
/// declare its `supportedActionTypes`, and register an instance here.
/// The executor needs zero edits.
@MainActor
struct NotificationActionRegistry {
    private let handlers: [NotificationActionType: any NotificationActionHandler]

    init(handlers: [any NotificationActionHandler]) {
        var byType: [NotificationActionType: any NotificationActionHandler] = [:]
        for handler in handlers {
            for type in handler.supportedActionTypes {
                byType[type] = handler
            }
        }
        self.handlers = byType
    }

    /// Default registry covering every `NotificationActionType` case.
    /// The list mirrors `NotificationActionType.allCases`; an assertion
    /// in `NotificationActionRegistryTests` fails the build if a new
    /// case is added without a handler registration.
    static func makeDefault() -> NotificationActionRegistry {
        NotificationActionRegistry(handlers: [
            // Basic
            ShowNotificationActionHandler(),
            PlaySoundActionHandler(),
            FocusWindowActionHandler(),
            DockBounceActionHandler(),
            BadgeTabActionHandler(),
            StyleTabActionHandler(),
            // Automation
            RunScriptActionHandler(),
            RunShortcutActionHandler(),
            ExecuteSnippetActionHandler(),
            // Integration
            WebhookActionHandler(),
            SendSlackActionHandler(),
            SendDiscordActionHandler(),
            // DevOps
            DockerBumpActionHandler(),
            DockerComposeActionHandler(),
            KubernetesRolloutActionHandler(),
            // Productivity
            CopyToClipboardActionHandler(),
            WriteToFileActionHandler(),
            OpenURLActionHandler(),
            GitCommitActionHandler(),
            // Accessibility
            VoiceAnnounceActionHandler(),
            FlashScreenActionHandler(),
            MenuBarAlertActionHandler(),
            // Time tracking (one handler shared across the three types
            // so they share their activeTimers state)
            TimeTrackingActionHandler()
        ])
    }

    func handler(for actionType: NotificationActionType) -> (any NotificationActionHandler)? {
        handlers[actionType]
    }

    var registeredActionTypes: Set<NotificationActionType> {
        Set(handlers.keys)
    }
}
