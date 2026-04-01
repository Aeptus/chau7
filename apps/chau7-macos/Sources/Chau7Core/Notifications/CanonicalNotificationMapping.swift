import Foundation

public enum NotificationSemanticMapping {
    public static func kind(
        rawType: String?,
        notificationType: String? = nil
    ) -> NotificationSemanticKind {
        if let notificationType, let mapped = kind(forNotificationType: notificationType) {
            return mapped
        }
        if let rawType, let mapped = kind(forRawType: rawType) {
            return mapped
        }
        return .unknown
    }

    public static func kind(forNotificationType value: String) -> NotificationSemanticKind? {
        switch normalize(value) {
        case "permission_prompt", "permissionrequest", "permission":
            return .permissionRequired
        case "idle_prompt", "idleprompt", "waiting_input", "waitinginput", "input_required", "inputrequired":
            return .waitingForInput
        case "auth_success", "authsuccess", "authentication_succeeded", "authenticationsucceeded", "login_success", "loginsuccess":
            return .authenticationSucceeded
        case "elicitation_dialog", "elicitationdialog", "attention_required", "attentionrequired", "needs_attention", "needsattention":
            return .attentionRequired
        default:
            return nil
        }
    }

    public static func kind(forRawType value: String) -> NotificationSemanticKind? {
        switch normalize(value) {
        case "finished", "response_complete", "responsecomplete", "task_finished", "taskfinished":
            return .taskFinished
        case "failed", "error", "context_limit", "contextlimit", "exit_failed", "exitfailed":
            return .taskFailed
        case "permission", "permission_request", "permissionrequest":
            return .permissionRequired
        case "waiting_input", "waitinginput", "idle_prompt", "idleprompt":
            return .waitingForInput
        case "attention_required", "attentionrequired", "notification":
            return .attentionRequired
        case "auth_success", "authsuccess":
            return .authenticationSucceeded
        case "idle":
            return .idle
        case "informational", "info":
            return .informational
        default:
            return nil
        }
    }

    public static func normalize(_ value: String) -> String {
        let normalizedWhitespace = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")

        return normalizedWhitespace
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .joined(separator: "_")
    }
}
