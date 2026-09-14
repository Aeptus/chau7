public enum MCPConnectionLifetimePolicy {
    /// Local MCP connections are protocol sessions, not request-scoped HTTP
    /// calls. A quiet initialized client remains valid until either peer closes
    /// the Unix socket; subscription heartbeats remain an opt-in data feature.
    public static let receiveTimeoutSeconds: Int? = nil

    /// A peer that stops reading must not block a session writer forever.
    public static let sendTimeoutSeconds = 30
}
