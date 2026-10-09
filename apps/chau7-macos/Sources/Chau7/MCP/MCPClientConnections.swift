import Foundation

/// Confined to the MCP server queue. Sessions own their descriptors from
/// admission through reader teardown, including when the server restarts.
final class MCPClientConnections {
    private var sessions: [Int32: MCPSession] = [:]

    var count: Int {
        sessions.count
    }

    func insert(_ session: MCPSession, descriptor: Int32) {
        sessions[descriptor] = session
    }

    func remove(_ session: MCPSession, descriptor: Int32) {
        // A completed session's callback can arrive after a restart and fd
        // reuse. It must not remove the replacement session's registration.
        guard sessions[descriptor] === session else { return }
        sessions.removeValue(forKey: descriptor)
    }

    func stopAll() {
        for session in sessions.values {
            session.stop()
        }
        sessions.removeAll()
    }
}
