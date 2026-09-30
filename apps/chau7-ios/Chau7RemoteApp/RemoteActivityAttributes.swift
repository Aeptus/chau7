/// ActivityKit attributes for Live Activities and Dynamic Island.
///
/// Each activity tracks a single remote tab, displaying the current tool,
/// project, headline, and approval state. Updated when the Mac sends
/// `RemoteActivityState` frames over the relay.
import ActivityKit
import Foundation
import Chau7Core

struct Chau7RemoteActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        let tabID: UInt32
        let tabTitle: String
        let toolName: String
        let projectName: String?
        let headline: String
        let detail: String?
        let status: RemoteActivityStatus
        let updatedAt: Date
        let approvalRequestID: String?
    }

    let activityID: String
}

extension Chau7RemoteActivityAttributes.ContentState {
    /// - Parameter redactDetails: when true, the free-form `detail` text is
    ///   dropped. It carries the raw command / flagged action for an approval,
    ///   which is exactly what the "Hide Details on Lock Screen" setting exists
    ///   to withhold. The Live Activity is the only surface that renders it
    ///   while the phone is locked, so it has to honour the same preference as
    ///   local notifications.
    init(state: RemoteActivityState, redactDetails: Bool = false) {
        self.init(
            tabID: state.tabID,
            tabTitle: state.tabTitle,
            toolName: state.toolName,
            projectName: state.projectName,
            headline: state.headline,
            detail: redactDetails ? nil : state.detail,
            status: state.status,
            updatedAt: state.updatedAt,
            approvalRequestID: state.approval?.requestID
        )
    }
}
