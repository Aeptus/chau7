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

    public static func kind(
        rawType: String?,
        notificationType: String? = nil,
        canonicalType: String?
    ) -> NotificationSemanticKind {
        if let notificationType, let mapped = kind(forNotificationType: notificationType) {
            return mapped
        }

        let rawKind = rawType.flatMap(kind(forRawType:)) ?? .unknown
        if let canonicalType,
           let canonicalKind = kind(forRawType: canonicalType),
           rawKind == .unknown || rawTypeShouldYieldToCanonical(rawType) {
            return canonicalKind
        }

        return rawKind
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
        case "finished", "response_complete", "responsecomplete", "task_finished", "taskfinished", "agent_turn_complete", "agentturncomplete":
            return .taskFinished
        case "failed", "error", "context_limit", "contextlimit", "exit_failed", "exitfailed",
             "tool_failed", "toolfailed", "response_failed", "responsefailed":
            return .taskFailed
        case "permission", "permission_request", "permissionrequest", "approval_requested", "approvalrequested":
            return .permissionRequired
        case "waiting_input", "waitinginput", "idle_prompt", "idleprompt", "user_input_requested", "userinputrequested":
            return .waitingForInput
        case "attention_required", "attentionrequired", "notification", "elicitation":
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

    private static func rawTypeShouldYieldToCanonical(_ rawType: String?) -> Bool {
        guard let rawType else { return true }
        switch normalize(rawType) {
        case "notification", "idle":
            return true
        default:
            return false
        }
    }

    public static func isInputPromptLike(
        title: String?,
        message: String,
        notificationType: String?
    ) -> Bool {
        if let notificationType,
           kind(forNotificationType: notificationType) == .waitingForInput {
            return true
        }

        let haystack = [title, message]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .joined(separator: " ")

        return haystack.contains("waiting for input")
            || haystack.contains("waiting for your input")
            || haystack.contains("needs your input")
            || haystack.contains("input requested")
            || haystack.contains("question requested")
            || haystack.contains("ready for your input")
    }
}
