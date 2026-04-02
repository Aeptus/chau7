import Foundation

/// Detects when multiple tabs modify the same file, indicating potential merge conflicts.
@MainActor
@Observable
final class ConflictDetector {
    static let shared = ConflictDetector()

    private(set) var activeConflicts: [FileConflict] = []

    /// How far back to look at command blocks for changed files (seconds).
    var lookbackWindow: TimeInterval = 300 // 5 minutes
    private weak var appModel: AppModel?

    private init() {}

    func configure(appModel: AppModel) {
        self.appModel = appModel
    }

    /// Check all tabs for overlapping changed files. Call after any command finishes.
    func checkForConflicts() {
        let blocksByTab = CommandBlockManager.shared.blocksByTab
        let cutoff = Date().addingTimeInterval(-lookbackWindow)

        // Collect recent changed files per tab
        var filesByTab: [String: (tabID: UUID, files: Set<String>)] = [:]
        for (tabIDString, blocks) in blocksByTab {
            guard let tabID = UUID(uuidString: tabIDString) else { continue }
            var files = Set<String>()
            for block in blocks.reversed() {
                guard let endTime = block.endTime, endTime > cutoff else { continue }
                guard !block.changedFiles.isEmpty else { continue }
                files.formUnion(block.changedFiles)
            }
            if !files.isEmpty {
                filesByTab[tabIDString] = (tabID: tabID, files: files)
            }
        }

        // Build file → tabs map
        var fileToTabs: [String: Set<UUID>] = [:]
        for (_, entry) in filesByTab {
            for file in entry.files {
                fileToTabs[file, default: []].insert(entry.tabID)
            }
        }

        // Find conflicts (files touched by 2+ tabs)
        var conflicts: [FileConflict] = []
        var newConflicts: [FileConflict] = []
        for (file, tabs) in fileToTabs where tabs.count > 1 {
            // Check if this conflict already exists (keep same ID for stability)
            if let existing = activeConflicts.first(where: { $0.filePath == file && $0.tabIDs == tabs }) {
                conflicts.append(existing)
            } else {
                let conflict = FileConflict(
                    id: UUID(),
                    filePath: file,
                    repoRoot: "",
                    tabIDs: tabs,
                    detectedAt: Date()
                )
                conflicts.append(conflict)
                newConflicts.append(conflict)
            }
        }

        if conflicts != activeConflicts {
            activeConflicts = conflicts
        }

        emitEvents(for: newConflicts)
    }

    /// Get conflicts that involve a specific tab.
    func conflictsForTab(_ tabID: UUID) -> [FileConflict] {
        activeConflicts.filter { $0.tabIDs.contains(tabID) }
    }

    private func emitEvents(for conflicts: [FileConflict]) {
        guard let appModel, !conflicts.isEmpty else { return }
        for conflict in conflicts {
            let fileName = URL(fileURLWithPath: conflict.filePath).lastPathComponent
            let label = fileName.isEmpty ? conflict.filePath : fileName
            let message = "Potential file conflict: \(label) changed in \(conflict.tabIDs.count) tabs"
            for tabID in conflict.tabIDs {
                appModel.recordEvent(
                    source: .app,
                    type: "file_conflict",
                    tool: "Chau7",
                    message: message,
                    notify: true,
                    tabID: tabID
                )
            }
        }
    }
}

struct FileConflict: Identifiable, Equatable {
    let id: UUID
    let filePath: String
    let repoRoot: String
    let tabIDs: Set<UUID>
    let detectedAt: Date
}
