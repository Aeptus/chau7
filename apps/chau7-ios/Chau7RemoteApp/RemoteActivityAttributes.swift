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
    init(state: RemoteActivityState) {
        self.init(
            tabID: state.tabID,
            tabTitle: state.tabTitle,
            toolName: state.toolName,
            projectName: state.projectName,
            headline: state.headline,
            detail: state.detail,
            status: state.status,
            updatedAt: state.updatedAt,
            approvalRequestID: state.approval?.requestID
        )
    }
}
