import Foundation
import Chau7Core

/// Repo-aware tab grouping — tags each tab with the git root of its
/// session so `tabBarSegments` can render grouped tab pills, and keeps
/// the tag in sync as the shell's `cd`/`git init` activity changes the
/// visible repo.
///
/// Mode semantics (from `FeatureSettings.repoGroupingMode`):
///   - `.off`   — tags stay as-is, auto-update subscriptions disabled.
///     Manual `addTabToRepoGroup` / `removeTabFromRepoGroup` still work.
///   - `.auto`  — every tab's `repoGroupID` tracks its session's
///     `gitRootPath` continuously. New tabs join automatically.
///   - `.manual`— tags are user-controlled; auto-update subscriptions
///     disabled. `tabBarSegments` still renders existing tags.
///
/// The mode-change observer is wired from `setupRepoGrouping()` at
/// model init; teardown happens in the model's `deinit` via
/// `repoGroupingModeObserver`.
extension OverlayTabsModel {
    func setupRepoGrouping() {
        repoGroupingModeObserver = NotificationCenter.default.addObserver(
            forName: .repoGroupingModeChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleRepoGroupingModeChange(FeatureSettings.shared.repoGroupingMode)
        }

        // Set initial state
        if FeatureSettings.shared.repoGroupingMode == .auto {
            applyAutoGroupingToAllTabs()
        }
    }

    func handleRepoGroupingModeChange(_ mode: RepoGroupingMode) {
        switch mode {
        case .off:
            // Keep existing repoGroupIDs — tabBarSegments always renders them.
            // Only stop auto-update subscriptions.
            clearAllGitRootCallbacks()
        case .auto:
            applyAutoGroupingToAllTabs()
        case .manual:
            // Keep existing groups, stop auto-updates
            clearAllGitRootCallbacks()
        }
    }

    private func clearAllGitRootCallbacks() {
        for tab in tabs {
            tab.session?.onGitRootPathChanged = nil
        }
    }

    func applyAutoGroupingToAllTabs() {
        clearAllGitRootCallbacks()
        for i in tabs.indices {
            // The previous fallback chain ended with `?? tabs[i].repoGroupID`,
            // which kept a stale tag when neither the session nor known-roots
            // could confirm membership. That preserved e.g. a `/Chau7` tag on
            // a tab whose cwd had moved to `/Aethyme` and whose gitRootPath
            // hadn't resolved yet. In auto mode the honest answer is "no
            // group" until something authoritative confirms one.
            tabs[i].repoGroupID = tabs[i].session?.gitRootPath ?? knownRepoRoot(for: tabs[i])
            tabs[i].hasInheritedRepoGroup = false
            if let session = tabs[i].session {
                observeGitRootForAutoGrouping(tabID: tabs[i].id, session: session)
            }
        }
        var seen = Set<String>()
        for tab in tabs {
            guard let repoGroupID = tab.repoGroupID, seen.insert(repoGroupID).inserted else { continue }
            coalesceGroup(repoGroupID: repoGroupID)
        }
    }

    func observeGitRootForAutoGrouping(tabID: UUID, session: TerminalSessionModel) {
        session.onGitRootPathChanged = { [weak self] newRoot in
            DispatchQueue.main.async {
                guard let self,
                      let idx = self.tabs.firstIndex(where: { $0.id == tabID }) else { return }

                if FeatureSettings.shared.repoGroupingMode == .auto {
                    // KnownRepoRootResolver only returns the existing
                    // preferred root when the new cwd is actually inside it,
                    // so this resolves to nil instead of preserving a stale
                    // tag whose path no longer contains the cwd.
                    self.tabs[idx].repoGroupID = newRoot ?? self.knownRepoRoot(for: self.tabs[idx])
                    self.tabs[idx].hasInheritedRepoGroup = false
                    if let repoGroupID = self.tabs[idx].repoGroupID {
                        self.coalesceGroup(repoGroupID: repoGroupID)
                    }
                    return
                }

                if self.tabs[idx].hasInheritedRepoGroup,
                   self.tabs[idx].repoGroupID != newRoot {
                    self.tabs[idx].repoGroupID = nil
                    self.tabs[idx].hasInheritedRepoGroup = false
                }
            }
        }
    }

    /// Called when a new tab is added — always assign repoGroupID from gitRootPath
    /// and subscribe to future changes. The mode only controls whether the user sees
    /// grouping controls in settings, not whether tabs get tagged (since tabBarSegments
    /// always renders existing groups).
    func setupRepoGroupingForTab(_ tab: OverlayTab) {
        guard let session = tab.session else { return }
        if let idx = tabs.firstIndex(where: { $0.id == tab.id }) {
            if tabs[idx].repoGroupID == nil {
                tabs[idx].repoGroupID = session.gitRootPath ?? knownRepoRoot(for: tabs[idx])
            }
            let repoGroupID = tabs[idx].repoGroupID
            if let repoGroupID {
                coalesceGroup(repoGroupID: repoGroupID)
            }
        }
        observeGitRootForAutoGrouping(tabID: tab.id, session: session)
    }

    private func knownRepoRoot(for tab: OverlayTab) -> String? {
        guard let session = tab.session else {
            return nil
        }

        return KnownRepoRootResolver.resolve(
            currentDirectory: session.currentDirectory,
            preferredRepoRoot: tab.repoGroupID,
            recentRepoRoots: KnownRepoIdentityStore.shared.allRoots()
        )
    }

    func insertionIndexForNewTab(inheritingRepoGroupID inheritedRepoGroupID: String?) -> Int {
        if inheritedRepoGroupID != nil,
           let currentIndex = tabs.firstIndex(where: { $0.id == selectedTabID }) {
            return currentIndex + 1
        }

        let position = FeatureSettings.shared.newTabPosition
        if position == "after",
           let currentIndex = tabs.firstIndex(where: { $0.id == selectedTabID }) {
            return currentIndex + 1
        }
        return tabs.count
    }

    /// Called when a tab is closed — clean up subscription.
    func cleanupRepoGroupingForTab(_ tabID: UUID) {
        if let tab = tabs.first(where: { $0.id == tabID }) {
            tab.session?.onGitRootPathChanged = nil
        }
    }

    /// Manual mode actions
    func addTabToRepoGroup(tabID: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == tabID }),
              let root = (tabs[idx].displaySession ?? tabs[idx].session)?.gitRootPath else { return }
        tabs[idx].repoGroupID = root
        tabs[idx].hasInheritedRepoGroup = false
        coalesceGroup(repoGroupID: root)
    }

    func removeTabFromRepoGroup(tabID: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[idx].repoGroupID = nil
        tabs[idx].hasInheritedRepoGroup = false
    }

    /// Toggle the agent dashboard overlay for a repo group.
    /// Click group tag → show dashboard. Click again or click any tab → dismiss.
    func toggleDashboard(for repoGroupID: String) {
        if activeDashboardGroupID == repoGroupID {
            activeDashboardGroupID = nil
        } else {
            _ = dashboardModel(for: repoGroupID)
            activeDashboardGroupID = repoGroupID
        }
    }

    func groupAllSameRepo(asTab tabID: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == tabID }),
              let root = (tabs[idx].displaySession ?? tabs[idx].session)?.gitRootPath else { return }
        for i in tabs.indices {
            if (tabs[i].displaySession ?? tabs[i].session)?.gitRootPath == root {
                tabs[i].repoGroupID = root
                tabs[i].hasInheritedRepoGroup = false
            }
        }
        coalesceGroup(repoGroupID: root)
    }

    func coalesceGroup(repoGroupID: String) {
        let order = TabBarLayout.coalescedOrder(
            groupIDs: tabs.map(\.repoGroupID),
            targetGroupID: repoGroupID
        )
        guard order != Array(tabs.indices) else { return }
        tabs = order.map { tabs[$0] }
    }
}
