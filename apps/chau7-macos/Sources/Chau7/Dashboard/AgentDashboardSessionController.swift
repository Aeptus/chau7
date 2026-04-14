import Foundation

protocol AgentDashboardSessionControlling {
    func allSessions(includeStopped: Bool) -> [RuntimeSession]
    @discardableResult
    func stopSession(id: String) -> Bool
    func startSession(arguments: [String: Any]) -> String
}

final class RuntimeAgentDashboardSessionController: AgentDashboardSessionControlling {
    static let shared = RuntimeAgentDashboardSessionController()

    private init() {}

    func allSessions(includeStopped: Bool) -> [RuntimeSession] {
        RuntimeSessionManager.shared.allSessions(includeStopped: includeStopped)
    }

    @discardableResult
    func stopSession(id: String) -> Bool {
        RuntimeSessionManager.shared.stopSession(id: id)
    }

    func startSession(arguments: [String: Any]) -> String {
        RuntimeControlService.shared.handleToolCall(
            name: "runtime_session_create",
            arguments: arguments
        )
    }
}
