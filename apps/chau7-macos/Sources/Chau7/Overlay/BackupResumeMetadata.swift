import Chau7Core
import Foundation

/// Decode only identity metadata from legacy full backups. JSONDecoder skips
/// scrollback, preview images and command blocks instead of materializing them.
struct BackupResumeWindows: Decodable {
    let windows: [[BackupResumeTab]]
}

struct BackupResumeTab: Decodable {
    let tabID: String?
    let aiResumeCommand: String?
    let aiProvider: String?
    let aiSessionId: String?
    let aiSessionIdSource: AISessionIdentitySource?
    let paneStates: [BackupResumePane]?

    var state: SavedTabState {
        SavedTabState(
            tabID: tabID, selectedTabID: nil, customTitle: nil, color: "",
            directory: "", selectedIndex: nil, tokenOptOverride: nil,
            scrollbackContent: nil, aiResumeCommand: aiResumeCommand,
            aiProvider: aiProvider, aiSessionId: aiSessionId, aiSessionIdSource: aiSessionIdSource,
            splitLayout: nil, focusedPaneID: nil, paneStates: paneStates?.map(\.state)
        )
    }
}

struct BackupResumePane: Decodable {
    let paneID: String
    let directory: String
    let aiResumeDirectory: String?
    let aiResumeCommand: String?
    let aiProvider: String?
    let aiSessionId: String?
    let aiSessionIdSource: AISessionIdentitySource?

    var state: SavedTerminalPaneState {
        SavedTerminalPaneState(
            paneID: paneID, directory: directory, scrollbackContent: nil,
            aiResumeCommand: aiResumeCommand, aiResumeDirectory: aiResumeDirectory,
            aiProvider: aiProvider, aiSessionId: aiSessionId, aiSessionIdSource: aiSessionIdSource
        )
    }
}

extension SavedTabState {
    func needsAIResumeBackup(recoverEmptyIdentities: Bool) -> Bool {
        let hasTopLevelIdentity = aiProvider != nil || aiSessionId != nil || aiResumeCommand != nil
        let paneScore = paneStates?.reduce(0) { $0 + $1.aiResumeRestorationScore } ?? 0
        let topLevelScore = aiResumeRestorationScore - paneScore
        if hasTopLevelIdentity || (recoverEmptyIdentities && (paneStates?.isEmpty ?? true)), topLevelScore < 150 {
            return true
        }
        return paneStates?.contains {
            ($0.hasAIResumePayload || recoverEmptyIdentities) && $0.aiResumeRestorationScore < 150
        } ?? false
    }
}
