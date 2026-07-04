import Foundation

public struct MagiAgentLaunchAssessment: Equatable {
    public var launchStatus: String
    public var promptStatus: String
    public var promptInputVisible: Bool?
    public var promptSubmitted: Bool?
    public var agentRunning: Bool?
    public var failureReason: String?

    public var accepted: Bool {
        failureReason == nil
    }

    public var promptVerificationFieldsComplete: Bool {
        promptInputVisible != nil && promptSubmitted != nil && agentRunning != nil
    }

    public var promptInputVisibleLogValue: String {
        Self.logValue(promptInputVisible)
    }

    public var promptSubmittedLogValue: String {
        Self.logValue(promptSubmitted)
    }

    public var agentRunningLogValue: String {
        Self.logValue(agentRunning)
    }

    public init(
        launchStatus: String,
        promptStatus: String,
        promptInputVisible: Bool?,
        promptSubmitted: Bool?,
        agentRunning: Bool?,
        failureReason: String?
    ) {
        self.launchStatus = launchStatus
        self.promptStatus = promptStatus
        self.promptInputVisible = promptInputVisible
        self.promptSubmitted = promptSubmitted
        self.agentRunning = agentRunning
        self.failureReason = failureReason
    }

    private static func logValue(_ value: Bool?) -> String {
        guard let value else { return "missing" }
        return value ? "true" : "false"
    }
}

public enum MagiAgentLaunchContract {
    public static func assess(
        _ agent: MagiMCPAgentLaunchAgent,
        tabID: String
    ) -> MagiAgentLaunchAssessment {
        let launchStatus = displayValue(agent.status)
        let promptStatus = displayValue(agent.promptStatus)
        let failureReason = failureReason(
            for: agent,
            tabID: tabID,
            launchStatus: launchStatus
        )

        return MagiAgentLaunchAssessment(
            launchStatus: launchStatus,
            promptStatus: promptStatus,
            promptInputVisible: agent.promptInputVisible,
            promptSubmitted: agent.promptSubmitted,
            agentRunning: agent.agentRunning,
            failureReason: failureReason
        )
    }

    private static func failureReason(
        for agent: MagiMCPAgentLaunchAgent,
        tabID: String,
        launchStatus: String
    ) -> String? {
        guard agent.status == "launched" else {
            return agent.error ?? "agent_launch returned status \(launchStatus)"
        }

        guard agent.promptVerificationFieldsComplete,
              let inputVisible = agent.promptInputVisible,
              let submitted = agent.promptSubmitted,
              let running = agent.agentRunning else {
            return "agent_launch response for \(tabID) did not include complete prompt verification fields"
        }

        let promptAccepted = AgentPromptInjectionPolicy.accepted(
            status: agent.promptStatus,
            inputVisible: inputVisible,
            submitted: submitted,
            running: running
        )
        guard promptAccepted else {
            return agent.error ?? "provider launched in \(tabID), but Chau7 did not detect an attached agent for prompt injection"
        }

        guard inputVisible || (submitted && running) else {
            return agent.error ?? "provider launched in \(tabID), but Chau7 did not confirm prompt text visibility or a submitted running agent"
        }
        guard submitted else {
            return agent.error ?? "provider launched in \(tabID), but Chau7 did not confirm prompt submission"
        }
        guard running else {
            return agent.error ?? "provider launched in \(tabID), but the tab did not report a running agent after submission"
        }

        return nil
    }

    private static func displayValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "missing" : trimmed
    }
}
