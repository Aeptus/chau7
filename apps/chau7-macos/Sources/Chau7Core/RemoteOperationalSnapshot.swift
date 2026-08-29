import Foundation

/// Privacy-safe, correlated state for the independent links that make up a
/// Chau7 Remote connection. Keeping this formatter in Chau7Core makes the
/// operational log contract deterministic and testable.
public struct RemoteOperationalSnapshot: Equatable, Sendable {
    public let agent: String
    public let ipc: String
    public let relay: String
    public let session: String
    public let tabCount: Int
    public let stream: String

    public init(
        agent: String,
        ipc: String,
        relay: String,
        session: String,
        tabCount: Int,
        stream: String
    ) {
        self.agent = agent
        self.ipc = ipc
        self.relay = relay
        self.session = session
        self.tabCount = max(0, tabCount)
        self.stream = stream
    }

    public var summary: String {
        "agent=\(agent) ipc=\(ipc) relay=\(relay) session=\(session) " +
            "tabs=\(tabCount) stream=\(stream)"
    }
}
