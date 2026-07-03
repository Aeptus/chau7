import Foundation
import Chau7Core

/// The remote side of the MCP↔Remote boundary, as seen from
/// `TerminalControlService`. Consumer-owned seam so the MCP layer forwards
/// approval requests through an abstraction instead of dereferencing
/// `RemoteControlManager.shared`. Wired at the composition root
/// (`Chau7App.init`); nil in tests, where no remote stack exists.
@MainActor
protocol MCPApprovalForwarding: AnyObject {
    func sendApprovalRequest(requestID: String, payload: ApprovalRequestPayload)
}
