import Foundation
import Combine

/// Detects when multiple tabs modify the same file, indicating potential merge conflicts.
final class ConflictDetector: ObservableObject {
    static let shared = ConflictDetector()

    @Published private(set) var activeConflicts: [FileConflict] = []

    /// How far back to look at command blocks for changed files (seconds).
    var lookbackWindow: TimeInterval = 300 // 5 minutes

    private init() {}

    /// Check all tabs for overlapping changed files. Call after any command finishes.
    @MainActor
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
        for (file, tabs) in fileToTabs where tabs.count > 1 {
            // Check if this conflict already exists (keep same ID for stability)
            if let existing = activeConflicts.first(where: { $0.filePath == file && $0.tabIDs == tabs }) {
                conflicts.append(existing)
            } else {
                conflicts.append(FileConflict(
                    id: UUID(),
                    filePath: file,
                    repoRoot: "",
                    tabIDs: tabs,
                    detectedAt: Date()
                ))
            }
        }

        if conflicts != activeConflicts {
            activeConflicts = conflicts
        }
    }

    /// Get conflicts that involve a specific tab.
    func conflictsForTab(_ tabID: UUID) -> [FileConflict] {
        activeConflicts.filter { $0.tabIDs.contains(tabID) }
    }
}

struct FileConflict: Identifiable, Equatable {
    let id: UUID
    let filePath: String
    let repoRoot: String
    let tabIDs: Set<UUID>
    let detectedAt: Date
}
