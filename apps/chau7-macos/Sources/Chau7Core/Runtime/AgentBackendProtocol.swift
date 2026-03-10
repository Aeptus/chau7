import Foundation

/// Describes how to launch and interact with a specific AI CLI agent.
///
/// Each backend knows how to construct the launch command, format prompt input
/// for the agent's stdin, and identify the provider for session resume.
/// Backends are stateless — session state lives in `RuntimeSession`.
public protocol AgentBackend: Sendable {
    /// Display name (e.g. "claude", "codex", "shell").
    var name: String { get }

    /// Shell command to launch the backend in a terminal tab.
    func launchCommand(config: SessionConfig) -> String

    /// Format a prompt for the agent's stdin. Returns the string to send to the PTY.
    func formatPromptInput(_ prompt: String, context: String?) -> String

    /// Provider key for session resume (e.g. Claude's `--resume` flag).
    /// Nil if the backend doesn't support resume.
    var resumeProviderKey: String? { get }
}

/// Configuration for creating a runtime session.
public struct SessionConfig: Codable, Sendable {
    /// Working directory for the session.
    public let directory: String
    /// Backend provider name (e.g. "claude", "codex", "shell").
    public let provider: String
    /// Model override (e.g. "opus", "sonnet").
    public let model: String?
    /// Resume an existing agent session by ID.
    public let resumeSessionID: String?
    /// Extra environment variables for the launched process.
    public let environment: [String: String]
    /// Additional CLI arguments for the backend.
    public let args: [String]

    public init(
        directory: String,
        provider: String,
        model: String? = nil,
        resumeSessionID: String? = nil,
        environment: [String: String] = [:],
        args: [String] = []
    ) {
        self.directory = directory
        self.provider = provider
        self.model = model
        self.resumeSessionID = resumeSessionID
        self.environment = environment
        self.args = args
    }
}
