import Foundation

// MARK: - Lightweight restore index

// The file restore bundle is the full primary source (scrollback in sidecars), but
// UserDefaults is the always-available fallback. To keep that fallback fresh on every
// autosave without re-introducing multi-MB plist writes, UserDefaults stores a
// *scrollback-stripped* index: identity and structure (tab/session IDs, directory,
// split layout, AI resume metadata, panes) are preserved so a fallback restore can
// reconstruct every tab; only the heavy regenerable payloads are dropped.

extension SavedTabState {
    /// A copy with scrollback, command blocks, and the preview image removed.
    var strippedForRestoreIndex: SavedTabState {
        SavedTabState(
            tabID: tabID,
            selectedTabID: selectedTabID,
            customTitle: customTitle,
            color: color,
            directory: directory,
            selectedIndex: selectedIndex,
            tokenOptOverride: tokenOptOverride,
            scrollbackContent: nil,
            aiResumeCommand: aiResumeCommand,
            aiProvider: aiProvider,
            aiSessionId: aiSessionId,
            aiSessionIdSource: aiSessionIdSource,
            splitLayout: splitLayout,
            focusedPaneID: focusedPaneID,
            paneStates: paneStates?.map { $0.strippedForRestoreIndex },
            createdAt: createdAt,
            repoGroupID: repoGroupID,
            knownRepoRoot: knownRepoRoot,
            knownGitBranch: knownGitBranch,
            lastInputAt: lastInputAt,
            lastStatus: lastStatus,
            agentLaunchCommand: agentLaunchCommand,
            agentStartedAt: agentStartedAt,
            lastExitCode: lastExitCode,
            lastExitAt: lastExitAt,
            commandBlocks: nil,
            previewSnapshotPNGData: nil
        )
    }
}

extension SavedTerminalPaneState {
    /// A copy with `scrollbackContent` removed; pane identity/session is preserved.
    var strippedForRestoreIndex: SavedTerminalPaneState {
        SavedTerminalPaneState(
            paneID: paneID,
            directory: directory,
            scrollbackContent: nil,
            aiResumeCommand: aiResumeCommand,
            aiResumeDirectory: aiResumeDirectory,
            aiProvider: aiProvider,
            aiSessionId: aiSessionId,
            aiSessionIdSource: aiSessionIdSource,
            lastOutputAt: lastOutputAt,
            lastInputAt: lastInputAt,
            knownRepoRoot: knownRepoRoot,
            knownGitBranch: knownGitBranch,
            lastStatus: lastStatus,
            agentLaunchCommand: agentLaunchCommand,
            agentStartedAt: agentStartedAt,
            lastExitCode: lastExitCode,
            lastExitAt: lastExitAt
        )
    }
}
