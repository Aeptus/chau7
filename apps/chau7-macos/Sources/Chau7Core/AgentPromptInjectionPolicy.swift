import Foundation

public enum AgentPromptInjectionPolicy {
    public static func accepted(
        status: String,
        inputVisible: Bool,
        submitted: Bool,
        running: Bool
    ) -> Bool {
        if status == "sent" || status == "skipped" {
            return true
        }
        return status == "sent_unverified" && !inputVisible && submitted && running
    }
}
