import AppKit
import CommonCrypto
import Foundation
import Chau7Core

/// Bridges MCP tool calls to Chau7's tab/terminal system.
/// All methods are safe to call from any thread — dispatches to main as needed.
///
/// Threading model: OverlayTabsModel lives on the main thread.
/// MCP sessions run on dedicated background queues. Read-only operations use
/// DispatchQueue.main.sync. Input-sending operations (execInTab, sendInput)
/// validate synchronously but send asynchronously via DispatchQueue.main.async
/// so PTY backpressure or input bookkeeping cannot stall the control-plane
/// caller while it is waiting for a response.
final class TerminalControlService {
    static let shared = TerminalControlService()

    /// Weak wrapper with a stable ID so window_id doesn't shift when models deallocate.
    private struct WeakModel {
        let windowID: Int
        weak var model: OverlayTabsModel?
    }

    private var registeredModels: [WeakModel] = []
    private var nextWindowID = 0
    private var mcpTabIDs = MCPTabIDAllocator()
    private var routingIndex = TabRoutingIndex(records: [])
    private var routingIndexNeedsRebuild = true
    private var learnedSessionRoutes: [String: UUID] = [:]
    var activeOverlayModelProvider: (() -> OverlayTabsModel?)?

    /// Hard ceiling — even if the user sets a higher value in settings.
    private static let absoluteMaxTabs = 50

    /// Maximum output size returned by tab_output (512 KB).
    private static let maxOutputBytes = 512 * 1024

    // MARK: - Pending Approvals

    /// Tracks in-flight approval requests so iOS responses can resolve them.
    private var pendingApprovals: [String: (MCPApprovalResult) -> Void] = [:]
    private var pendingApprovalDetails: [String: [String: Any]] = [:]
    private let approvalLock = NSLock()

    /// Register an overlay model. Call from AppDelegate for every new window.
    func register(_ model: OverlayTabsModel) {
        // Already registered? Skip.
        if registeredModels.contains(where: { $0.model === model }) { return }
        // Prune dead references
        registeredModels.removeAll { $0.model == nil }
        let id = nextWindowID
        nextWindowID += 1
        registeredModels.append(WeakModel(windowID: id, model: model))
        invalidateRoutingIndex(reason: "register_model")
    }

    /// Unregister when a window closes. Optional — dead refs are pruned lazily.
    func unregister(_ model: OverlayTabsModel) {
        registeredModels.removeAll { $0.model == nil || $0.model === model }
        invalidateRoutingIndex(reason: "unregister_model")
    }

    /// All currently alive (windowID, model) pairs, preserving stable IDs.
    var allModels: [(windowID: Int, model: OverlayTabsModel)] {
        registeredModels.compactMap { entry in
            guard let model = entry.model else { return nil }
            return (entry.windowID, model)
        }
    }

    /// All tabs across all registered windows. Use for cross-window resolution
    /// (e.g., notification routing that must search every window, not just window 0).
    var allTabs: [OverlayTab] {
        allModels.flatMap { $0.model.tabs }
    }

    func invalidateRoutingIndex(reason _: String) {
        onMain {
            self.routingIndexNeedsRebuild = true
        }
    }

    func resolveTabID(for target: TabTarget, strictSession: Bool = false) -> UUID? {
        onMain {
            self.resolveTabIDLocked(for: target, strictSession: strictSession)
        }
    }

    /// Snapshot of all routing-relevant tab/session records across all
    /// windows. Used by `TabAttribution` as its data source. Thread-safe;
    /// dispatches to main if needed.
    func routingRecords() -> [TabRouteRecord] {
        onMain { self.routingRecordsLocked() }
    }

    func resolveTab(for target: TabTarget, strictSession: Bool = false) -> OverlayTab? {
        onMain {
            guard let tabID = self.resolveTabIDLocked(for: target, strictSession: strictSession) else {
                return nil
            }
            return self.tabLocked(for: tabID)
        }
    }

    func tabTitle(for target: TabTarget) -> String? {
        resolveTab(for: target)?.displayTitle
    }

    func repoName(for target: TabTarget) -> String? {
        guard let tab = resolveTab(for: target),
              let session = tab.displaySession ?? tab.session,
              let rootPath = session.gitRootPath else { return nil }
        return URL(fileURLWithPath: rootPath).lastPathComponent
    }

    func isActiveTab(_ target: TabTarget) -> Bool {
        guard let tabID = resolveTabID(for: target) else { return false }
        return onMain {
            self.allModels.contains { $0.model.selectedTabID == tabID }
        }
    }

    @discardableResult
    func adoptHistorySession(_ request: HistorySessionAdoptionRequest) -> Bool {
        onMain {
            let target = TabTarget(
                tool: request.toolName,
                directory: request.directory,
                tabID: request.tabID,
                sessionID: request.sessionId
            )
            guard let tab = self.resolveTabLocked(for: target),
                  let session = self.historyAdoptionSession(in: tab, request: request) else {
                Log.trace(
                    "History adoption skipped: no compatible tab for tool=\(request.displayName) session=\(request.sessionId.prefix(8))"
                )
                return false
            }

            return session.adoptAIHistorySession(request)
        }
    }

    @discardableResult
    func applyNotificationStyleAcrossWindows(to tabID: UUID, stylePreset: String, config: [String: String]) -> UUID? {
        let models = allModels
        var foundTab = false
        for (_, model) in models {
            guard model.tabs.contains(where: { $0.id == tabID }) else { continue }
            foundTab = true
            if model.applyNotificationStyle(to: tabID, stylePreset: stylePreset, config: config) {
                return tabID
            }
        }
        if foundTab {
            Log.debug("applyNotificationStyle: tabID \(tabID) already matched requested style")
            return tabID
        }
        Log.warn("applyNotificationStyle: tabID \(tabID) not found across \(models.count) windows (\(models.flatMap(\.model.tabs).count) total tabs)")
        return nil
    }

    func tabExistsAcrossWindows(tabID: UUID) -> Bool {
        allTabs.contains { $0.id == tabID }
    }

    @discardableResult
    func focusTabAcrossWindows(tabID: UUID) -> Bool {
        for (_, model) in allModels {
            if model.focusTab(id: tabID) {
                return true
            }
        }
        Log.warn("focusTab: Explicit tabID not found across windows for tab \(tabID)")
        return false
    }

    @discardableResult
    func badgeTabAcrossWindows(tabID: UUID, text: String, color: String) -> Bool {
        for (_, model) in allModels {
            if model.setBadge(on: tabID, text: text, color: color) {
                return true
            }
        }
        Log.warn("setBadge: Explicit tabID not found across windows for tab \(tabID)")
        return false
    }

    @discardableResult
    func insertSnippetAcrossWindows(id snippetID: String, tabID: UUID, autoExecute: Bool) -> Bool {
        for (_, model) in allModels {
            if model.insertSnippet(id: snippetID, on: tabID, autoExecute: autoExecute) {
                return true
            }
        }
        Log.warn("insertSnippet: Explicit tabID not found across windows for tab \(tabID)")
        return false
    }

    /// Updates a tab's session-tracked cwd across all windows.
    ///
    /// Used when an upstream signal (e.g., a Claude Code hook event with the
    /// session's working directory) is more authoritative about the tab's
    /// current directory than what `OSC 7` from the host shell has reported.
    /// This is necessary for tabs hosting AI-tool TUIs (Claude Code, Codex):
    /// once the TUI takes over the alt screen, the host shell's `chpwd` hook
    /// no longer fires for `cd`s the user types into the TUI, so Chau7's
    /// tracked `currentDirectory` stays stuck at the pre-TUI value. The AI
    /// tool itself does know its working directory and emits it on every
    /// session event — feeding that back here keeps tab-pwd-derived UI
    /// (snippet context, repo grouping, telemetry) in sync.
    ///
    /// `sessionID` is the event's AI session id. When the tab has a live
    /// `lastAISessionId` that differs, the write is skipped — stale sessions
    /// that linger in `claude-events.jsonl` after a tab has been re-used for
    /// a new claude invocation would otherwise oscillate the tab's cwd
    /// between two unrelated directories.
    ///
    /// Returns true when an actual session was updated (vs. tab existing
    /// but having no live session yet — common during background-window
    /// lazy load).
    @discardableResult
    func updateSessionDirectoryAcrossWindows(
        tabID: UUID,
        sessionID: String?,
        directory: String
    ) -> Bool {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return onMain {
            for (_, model) in self.allModels {
                guard let tab = model.tabs.first(where: { $0.id == tabID }),
                      let session = tab.session
                else { continue }

                // Two-axis decision matrix (row = session, col = directory):
                //                     dir related   dir foreign
                //   session matches   accept        refuse  (stale binding,
                //                                              foreign cwd)
                //   session differs   accept+adopt  refuse  (foreign event for
                //                                              another tab)
                // i.e. accept iff directory is related; on accept, adopt the
                // new sessionID when it differs from the tab's live binding.
                let directoryIsRelated = !self.shouldRefuseCwdWriteAsForeign(
                    session: session,
                    newDirectory: trimmed
                )
                guard directoryIsRelated else {
                    Log.warn(
                        "updateSessionDirectory: refusing foreign-cwd write tab=\(tabID) " +
                            "session=\(sessionID ?? "nil") liveSession=\(session.lastAISessionId ?? "nil") " +
                            "tabCwd=\(session.currentDirectory) eventCwd=\(trimmed)"
                    )
                    return false
                }

                if let sessionID,
                   let live = session.lastAISessionId,
                   live != sessionID {
                    Log.info(
                        "updateSessionDirectory: adopting new session for tab=\(tabID) " +
                            "previous=\(live) new=\(sessionID) tabCwd=\(session.currentDirectory) " +
                            "tabGitRoot=\(session.gitRootPath ?? "nil") eventCwd=\(trimmed)"
                    )
                    session.lastAISessionId = sessionID
                }
                guard session.currentDirectory != trimmed else { return true }
                Log.trace(
                    "updateSessionDirectory: applying tab=\(tabID) " +
                        "session=\(sessionID ?? "nil") oldCwd=\(session.currentDirectory) " +
                        "newCwd=\(trimmed)"
                )
                session.updateCurrentDirectory(trimmed)
                return true
            }
            return false
        }
    }

    /// Returns true when `newDirectory` has no prefix relationship to either
    /// the session's current directory or its git root. A genuine cd inside a
    /// TUI moves between paths that share a parent (or at least relate to the
    /// tab's repo); a writeback for a totally unrelated path almost always
    /// means the session id is bound to the wrong tab.
    private func shouldRefuseCwdWriteAsForeign(
        session: TerminalSessionModel,
        newDirectory: String
    ) -> Bool {
        ForeignCwdPolicy.shouldRefuse(
            newDirectory: newDirectory,
            tabCurrentDirectory: session.currentDirectory,
            tabGitRoot: session.gitRootPath
        )
    }

    @discardableResult
    func clearPersistentNotificationStyleAcrossWindows(tabID: UUID) -> Bool {
        for (_, model) in allModels {
            if model.clearPersistentNotificationStyle(on: tabID) {
                return true
            }
        }
        // Tab exists in a model but style clear failed — likely a lazy-loaded tab
        // whose view hasn't materialized yet (e.g., Window 2 background tabs).
        let tabExistsInModel = allTabs.contains { $0.id == tabID }
        if tabExistsInModel {
            Log.debug("clearPersistentStyle: tabID \(tabID) exists but no persistent style to clear")
        } else {
            Log.warn("clearPersistentStyle: tabID \(tabID) not found across windows")
        }
        return false
    }

    @discardableResult
    func assertAttentionStyleAcrossWindows(
        tabID: UUID,
        kind: TabAttentionKind,
        reason: String,
        sessionID: String? = nil
    ) -> Bool {
        onMain {
            var foundTab = false
            for (_, model) in self.allModels {
                guard model.tabs.contains(where: { $0.id == tabID }) else { continue }
                foundTab = true
                if model.assertNotificationAttention(
                    tabID: tabID,
                    kind: kind,
                    sessionID: sessionID,
                    reason: reason
                ) {
                    return true
                }
            }
            if foundTab {
                Log.debug("assertAttentionStyle: tabID \(tabID) already matched requested attention")
            } else {
                Log.warn("assertAttentionStyle: tabID \(tabID) not found across \(self.allModels.count) windows")
            }
            return false
        }
    }

    @discardableResult
    func clearAttentionStateAcrossWindows(
        tabID: UUID,
        sessionID: String?,
        resolvedStatus: CommandStatus,
        reason: String
    ) -> Bool {
        onMain {
            var foundTab = false
            for (_, model) in self.allModels {
                guard model.tabs.contains(where: { $0.id == tabID }) else { continue }
                foundTab = true
                if model.clearNotificationAttention(
                    tabID: tabID,
                    sessionID: sessionID,
                    resolvedStatus: resolvedStatus,
                    reason: reason
                ) {
                    return true
                }
            }
            if foundTab {
                Log.debug("clearAttentionState: tabID \(tabID) had no interactive attention to clear")
            } else {
                Log.warn("clearAttentionState: tabID \(tabID) not found across \(self.allModels.count) windows")
            }
            return false
        }
    }

    // MARK: - Tab Operations

    func listTabs() -> String {
        onMain {
            self.encodeAny(self.liveTabSummaries())
        }
    }

    func liveTabSummaries() -> [[String: Any]] {
        // Must run on main — `allModels` / `model.tabs` / per-session
        // `@Observable` state are main-thread-owned, and `pruneTabAliases
        // Locked()` mutates `mcpTabIDs`. Without this hop, callers from the
        // MCP client queue (e.g. `Chau7StateSnapshotService.snapshotPayload`)
        // race against tab open/close/reorder and can crash in Swift's
        // Array COW on concurrent read+write. The class contract at the
        // top of this file promises all methods are safe from any thread.
        onMain {
            self.pruneTabAliasesLocked()
            let models = self.allModels
            guard !models.isEmpty else { return [] }
            var result: [[String: Any]] = []
            for (windowID, model) in models {
                for tab in model.tabs {
                    var summary = self.tabSummary(tab)
                    summary["window_id"] = windowID
                    let attentionReport = model.attentionReportPayload(for: tab)
                    summary["attention"] = attentionReport
                    summary["attention_report"] = attentionReport["compact"]
                    result.append(summary)
                }
            }
            return result
        }
    }

    func pendingApprovalSummaries() -> [[String: Any]] {
        approvalLock.lock()
        defer { approvalLock.unlock() }
        return pendingApprovalDetails.keys.sorted().compactMap { pendingApprovalDetails[$0] }
    }

    func repoEventSnapshots(limitPerRepo: Int = 5) -> [[String: Any]] {
        onMain {
            guard let appModel = self.allModels.first?.model.appModel else { return [] }
            let clampedLimit = max(1, min(limitPerRepo, 20))
            return appModel.eventsByRepo.keys.sorted().map { repoPath in
                let events = appModel.eventsByRepo[repoPath] ?? []
                let recent = Array(events.suffix(clampedLimit)).map { self.aiEventDictionary($0) }
                return [
                    "repo_path": repoPath,
                    "event_count": events.count,
                    "recent_events": recent,
                    "last_event_at": events.last?.ts as Any
                ].compactMapValues { $0 }
            }
        }
    }

    func createTab(directory: String?, windowID: Int?, context: String? = nil) -> String {
        onMain {
            let startedAt = CFAbsoluteTimeGetCurrent()
            defer {
                FeatureProfiler.shared.recordMainThreadStallIfNeeded(
                    operation: "TerminalControlService.createTab",
                    startedAt: startedAt,
                    thresholdMs: 120,
                    metadata: "context=\(context ?? "default") windowID=\(windowID.map(String.init) ?? "nil")"
                )
            }
            let settings = FeatureSettings.shared
            guard settings.mcpEnabled else {
                return self.jsonError("MCP is disabled in settings.")
            }

            let models = self.allModels
            guard !models.isEmpty else { return self.noWindowError() }

            let model: OverlayTabsModel
            let resolvedWindowID: Int
            if let wid = windowID {
                guard let entry = models.first(where: { $0.windowID == wid }) else {
                    let validIDs = models.map { String($0.windowID) }.joined(separator: ", ")
                    return self.jsonError("Invalid window_id: \(wid). Valid IDs: \(validIDs)")
                }
                model = entry.model
                resolvedWindowID = wid
            } else {
                guard let entry = self.preferredModelEntry(from: models) else {
                    return self.noWindowError()
                }
                model = entry.model
                resolvedWindowID = entry.windowID
            }

            // Resource protection: limit MCP-created tabs
            let maxTabs = min(settings.mcpMaxTabs, Self.absoluteMaxTabs)
            let mcpTabCount = model.tabs.filter { $0.isMCPControlled }.count
            if mcpTabCount >= maxTabs {
                return self.jsonError("MCP tab limit reached (\(maxTabs)). Close existing MCP tabs first.")
            }

            // Approval gate
            if settings.mcpRequiresApproval {
                let approved = self.requestApproval(
                    message: "MCP client wants to create a new tab\(directory.map { " in \($0)" } ?? "")."
                )
                if !approved {
                    return self.jsonError("Tab creation denied by user.")
                }
            }

            // Validate directory exists if provided
            if let dir = directory {
                var isDir: ObjCBool = false
                if !FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) || !isDir.boolValue {
                    return self.jsonError("Directory does not exist: \(dir)")
                }
            }

            let tabIDsBefore = Set(model.tabs.map(\.id))
            if let dir = directory {
                model.newTab(at: dir, selectNewTab: false)
            } else {
                model.newTab(selectNewTab: false)
            }

            // Find the newly created tab by UUID diff because MCP-created tabs open
            // in the background and do not become the selected tab.
            guard let tabIndex = model.tabs.firstIndex(where: { !tabIDsBefore.contains($0.id) }) else {
                return self.jsonError("Tab creation failed")
            }

            // Mark as MCP-controlled and assign repo group
            model.tabs[tabIndex].isMCPControlled = true
            model.setupRepoGroupingForTab(model.tabs[tabIndex])
            let tab = model.tabs[tabIndex]

            Log.info("MCP: tab created \(tab.id) dir=\(directory ?? "(inherited)")")

            return self.encodeAny([
                "tab_id": self.controlPlaneTabIDLocked(for: tab.id),
                "window_id": resolvedWindowID,
                "status": "created",
                "shell_loading": tab.session?.isShellLoading ?? true,
                "has_terminal_view": tab.session?.existingRustTerminalView != nil,
                "can_accept_exec": self.tabExecutionReadiness(for: tab.session).canAcceptExec,
                "exec_acceptance_mode": self.tabExecutionReadiness(for: tab.session).acceptanceMode.rawValue,
                "ready_for_exec": self.tabExecutionReadiness(for: tab.session).isReady,
                "readiness_reason": self.tabExecutionReadiness(for: tab.session).reason.rawValue
            ])
        }
    }

    func execInTab(tabID: String, command: String) -> String {
        let context = onMain { self.gatherTabContext(tabID) }
        let (verdict, permissions) = MCPCommandFilter.check(command, context: context)
        if let err = enforceVerdict(verdict, permissions: permissions, fullInput: command, context: "tab \(tabID)") {
            return err
        }

        // Validate tab existence and prompt state synchronously on main, but
        // send the actual input asynchronously. The control plane should not
        // wait inside input bookkeeping or PTY writes under backpressure.
        let validationResult: (
            isValid: Bool,
            error: String?,
            isLoading: Bool,
            isAtPrompt: Bool,
            detectedApp: String?
        ) = onMain {
            guard let (_, session) = self.resolveTab(tabID) else {
                return (false, self.jsonError("Tab not found: \(tabID)"), false, false, nil)
            }
            let detectedApp = CommandDetection.detectApp(from: command) ?? CommandDetection.detectLaunchableApp(
                from: command,
                currentDirectory: session.currentDirectory,
                searchPath: session.launchPATHValue()
            )
            return (true, nil, session.isShellLoading, session.isAtPrompt, detectedApp)
        }

        guard validationResult.isValid else {
            return validationResult.error!
        }

        if validationResult.isLoading {
            DispatchQueue.main.async {
                guard let (_, session) = self.resolveTab(tabID) else { return }
                if let detectedApp = validationResult.detectedApp {
                    session.activeAppName = detectedApp
                    session.updateLastDetectedApp(detectedApp)
                    session.startAILoggingIfNeeded(toolName: detectedApp, commandLine: command)
                }
                session.sendOrQueueInput(command + "\n")
            }
            Log.info("MCP: queued exec in \(tabID): \(command.prefix(80))")
            return encodeAny(["ok": true, "queued": true])
        }

        guard validationResult.isAtPrompt else {
            return jsonError("Tab is not at prompt (status: not at prompt). Wait for the current process to finish or use tab_send_input for interactive input.")
        }

        DispatchQueue.main.async {
            guard let (_, session) = self.resolveTab(tabID) else { return }
            if let detectedApp = validationResult.detectedApp {
                session.activeAppName = detectedApp
                session.updateLastDetectedApp(detectedApp)
                session.startAILoggingIfNeeded(toolName: detectedApp, commandLine: command)
            }
            session.sendInput(command + "\n")
        }
        Log.info("MCP: exec in \(tabID): \(command.prefix(80))")
        return encodeAny(["ok": true, "queued": false])
    }

    func tabStatus(tabID: String) -> String {
        onMain {
            guard let (tab, session) = self.resolveTab(tabID) else {
                return self.jsonError("Tab not found: \(tabID)")
            }

            var result: [String: Any] = self.tabSummary(tab)
            self.addExecutionReadinessFields(to: &result, session: session)

            // Add process group info
            if let pg = session.processGroup {
                result["processes"] = pg.children.map { proc in
                    [
                        "pid": proc.pid,
                        "name": proc.name,
                        "cpu_percent": proc.cpuPercent,
                        "rss_bytes": proc.rssBytes
                    ] as [String: Any]
                }
            }

            // Look up active telemetry run using the session's tabIdentifier
            // (which is what TelemetryRecorder uses — NOT the OverlayTab UUID)
            if let run = TelemetryRecorder.shared.activeRunForTab(session.tabIdentifier) {
                result["active_run"] = [
                    "run_id": run.id,
                    "provider": run.provider,
                    "started_at": TelemetryStore.isoString(from: run.startedAt),
                    "session_id": run.sessionID as Any,
                    "duration_so_far_ms": Int(Date().timeIntervalSince(run.startedAt) * 1000)
                ] as [String: Any]
            }

            return self.encodeAny(result)
        }
    }

    func waitForTabReady(tabID: String, timeoutMs: Int = 30000) -> String {
        let boundedTimeoutMs = max(0, min(timeoutMs, 120_000))
        let start = Date()

        guard var lastSnapshot = onMain({ self.tabReadinessSnapshot(tabID: tabID) }) else {
            return jsonError("Tab not found: \(tabID)")
        }

        if lastSnapshot["can_accept_exec"] as? Bool == true {
            return encodeAny([
                "tab_id": tabID,
                "can_accept_exec": true,
                "ready_for_exec": lastSnapshot["ready_for_exec"] as? Bool ?? false,
                "timed_out": false,
                "waited_ms": 0,
                "status": lastSnapshot
            ])
        }

        let deadline = start.addingTimeInterval(Double(boundedTimeoutMs) / 1000.0)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: min(0.1, max(0.01, deadline.timeIntervalSinceNow)))

            guard let snapshot = onMain({ self.tabReadinessSnapshot(tabID: tabID) }) else {
                return jsonError("Tab not found: \(tabID)")
            }
            lastSnapshot = snapshot

            if snapshot["can_accept_exec"] as? Bool == true {
                let waitedMs = Int(Date().timeIntervalSince(start) * 1000)
                return encodeAny([
                    "tab_id": tabID,
                    "can_accept_exec": true,
                    "ready_for_exec": snapshot["ready_for_exec"] as? Bool ?? false,
                    "timed_out": false,
                    "waited_ms": waitedMs,
                    "status": snapshot
                ])
            }
        }

        let waitedMs = Int(Date().timeIntervalSince(start) * 1000)
        return encodeAny([
            "tab_id": tabID,
            "can_accept_exec": false,
            "ready_for_exec": false,
            "timed_out": true,
            "waited_ms": waitedMs,
            "status": lastSnapshot
        ])
    }

    func sendInput(tabID: String, input: String) -> String {
        let context = onMain { self.gatherTabContext(tabID) }
        let (verdict, permissions) = MCPCommandFilter.checkRawInput(input, context: context)
        if let err = enforceVerdict(verdict, permissions: permissions, fullInput: input, context: "tab \(tabID)") {
            return err
        }

        // Validate tab existence synchronously, send input asynchronously.
        // Same control-plane isolation as execInTab: do not wait inside input
        // bookkeeping or PTY writes under backpressure.
        let tabExists: Bool = onMain {
            self.resolveTab(tabID) != nil
        }
        guard tabExists else {
            return jsonError("Tab not found: \(tabID)")
        }

        DispatchQueue.main.async {
            guard let (_, session) = self.resolveTab(tabID) else { return }
            session.sendOrQueueInput(input)
        }
        Log.info("MCP: send_input to \(tabID) (\(input.count) chars)")
        return encodeAny(["ok": true])
    }

    func pressKey(tabID: String, key: String, modifiers: [String]) -> String {
        let keyPress: TerminalKeyPress
        do {
            keyPress = try TerminalKeyPress(key: key, modifiers: modifiers)
            _ = try keyPress.encode()
        } catch {
            return jsonError(error.localizedDescription)
        }

        let tabExists: Bool = onMain {
            self.resolveTab(tabID) != nil
        }
        guard tabExists else {
            return jsonError("Tab not found: \(tabID)")
        }

        DispatchQueue.main.async {
            guard let (_, session) = self.resolveTab(tabID) else { return }
            session.sendOrQueueKeyPress(keyPress)
        }
        Log.info("MCP: press_key in \(tabID): key=\(keyPress.key) modifiers=\(keyPress.sortedModifierNames.joined(separator: "+"))")
        return encodeAny(["ok": true])
    }

    func submitPrompt(tabID: String) -> String {
        let keyPress: TerminalKeyPress
        do {
            keyPress = try TerminalKeyPress(key: "enter", modifiers: [])
            _ = try keyPress.encode()
        } catch {
            return jsonError(error.localizedDescription)
        }

        let initialState: AISubmitSnapshot? = onMain {
            guard let (_, session) = self.resolveTab(tabID) else { return nil }
            return self.submitSnapshot(for: session)
        }
        guard let initialState else {
            return jsonError("Tab not found: \(tabID)")
        }

        DispatchQueue.main.async {
            guard let (_, session) = self.resolveTab(tabID) else { return }
            session.sendOrQueueKeyPress(keyPress)
        }
        Log.info("MCP: submit_prompt in \(tabID): enter#1")

        guard AISubmitHeuristics.shouldObserveAfterFirstEnter(initialState) else {
            return encodeAny(["ok": true, "enter_count": 1])
        }

        let deadline = Date().addingTimeInterval(0.45)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.12)
            let currentState: AISubmitSnapshot? = onMain {
                guard let (_, session) = self.resolveTab(tabID) else { return nil }
                return self.submitSnapshot(for: session)
            }
            guard let currentState else {
                return encodeAny(["ok": true, "enter_count": 1])
            }

            if AISubmitHeuristics.workStarted(initial: initialState, current: currentState) {
                return encodeAny(["ok": true, "enter_count": 1])
            }

            if AISubmitHeuristics.shouldSendSecondEnter(initial: initialState, current: currentState) {
                DispatchQueue.main.async {
                    guard let (_, session) = self.resolveTab(tabID) else { return }
                    session.sendOrQueueKeyPress(keyPress)
                }
                Log.info("MCP: submit_prompt in \(tabID): enter#2 after prompt persisted")
                return encodeAny([
                    "ok": true,
                    "enter_count": 2,
                    "resolved_intermediate_prompt": true
                ])
            }
        }

        return encodeAny(["ok": true, "enter_count": 1])
    }

    func closeTab(tabID: String, force: Bool, context: String? = nil) -> String {
        onMain {
            let startedAt = CFAbsoluteTimeGetCurrent()
            defer {
                FeatureProfiler.shared.recordMainThreadStallIfNeeded(
                    operation: "TerminalControlService.closeTab",
                    startedAt: startedAt,
                    thresholdMs: 120,
                    metadata: "context=\(context ?? "default") force=\(force)"
                )
            }
            guard let uuid = self.resolveControlPlaneTabIDLocked(tabID) else {
                return self.jsonError("Invalid tab ID: \(tabID)")
            }
            guard let model = self.modelForTab(uuid) else {
                return self.jsonError("Tab not found: \(tabID)")
            }

            if !force {
                if let (_, session) = self.resolveTab(tabID),
                   session.status == .running
                   || session.status == .waitingForInput
                   || session.status == .approvalRequired
                   || session.status == .stuck {
                    return self.jsonError("Tab has a running process (status: \(session.status.rawValue)). Use force=true to close anyway.")
                }
            }

            Log.info("MCP: closing tab \(tabID) force=\(force) context=\(context ?? "default")")
            model.closeTab(id: uuid, skipWarning: true)
            self.mcpTabIDs.release(tabID: uuid)
            return self.encodeAny(["ok": true])
        }
    }

    func closeTabAsync(tabID: String, force: Bool, context: String? = nil) {
        DispatchQueue.main.async {
            _ = self.closeTab(tabID: tabID, force: force, context: context)
        }
    }

    func tabOutput(tabID: String, lines: Int, waitForStableMs: Int? = nil, source: String? = nil) -> String {
        // source=pty_log: return ANSI-stripped PTY log instead of terminal buffer.
        // Works for all AI tools regardless of alternate screen usage.
        if source == "pty_log" {
            return ptyLogOutput(tabID: tabID, lines: lines, waitForStableMs: waitForStableMs)
        }

        // If wait_for_stable_ms is requested, poll the buffer on the calling (MCP background)
        // thread, only briefly grabbing main for each snapshot. This avoids blocking the UI.
        if let waitMs = waitForStableMs, waitMs > 0 {
            let maxWaitMs = min(waitMs, 30000)
            // Content must be unchanged for this long to be considered stable.
            // The caller's wait_for_stable_ms is the total budget; we use a shorter
            // inner threshold so we return as soon as content settles.
            let stabilityThresholdMs = min(maxWaitMs, 500)
            let pollIntervalMs = 250
            let deadline = DispatchTime.now() + .milliseconds(maxWaitMs)
            var previousFingerprint: (Int, Data)?
            var stableSince: DispatchTime?

            while DispatchTime.now() < deadline {
                let fingerprint: (Int, Data)? = onMain {
                    guard let (_, session) = self.resolveTab(tabID) else { return nil }
                    guard let data = session.captureRemoteSnapshot() else { return nil }
                    return Self.bufferFingerprint(data)
                }

                // Tab closed or view detached — return what we have
                guard let fp = fingerprint else { break }

                if let prev = previousFingerprint,
                   fp.0 == prev.0, fp.1 == prev.1 {
                    // Content unchanged since last poll
                    if stableSince == nil { stableSince = DispatchTime.now() }
                    let stableMs = Int((DispatchTime.now().uptimeNanoseconds - stableSince!.uptimeNanoseconds) / 1_000_000)
                    if stableMs >= stabilityThresholdMs {
                        break // Buffer has been stable long enough
                    }
                } else {
                    // Content changed — reset stability timer
                    stableSince = nil
                    previousFingerprint = fp
                }

                Thread.sleep(forTimeInterval: Double(pollIntervalMs) / 1000.0)
            }
        }

        // Final capture and format from terminal buffer
        return onMain {
            guard let (tab, session) = self.resolveTab(tabID) else {
                return self.jsonError("Tab not found: \(tabID)")
            }

            let clampedLines = max(1, lines)

            guard let data = session.captureRemoteSnapshot() else {
                return self.encodeAny(["tab_id": self.controlPlaneTabIDLocked(for: tab.id), "output": "", "lines": 0])
            }

            return self.formatBufferOutput(tabID: tabID, data: data, lines: clampedLines)
        }
    }

    /// Returns the ANSI-stripped PTY log output for an AI session in a tab.
    /// This captures everything written to the terminal including alternate-screen
    /// content that TUI-based AI tools discard on exit.
    private func ptyLogOutput(tabID: String, lines: Int, waitForStableMs: Int? = nil) -> String {
        if let waitForStableMs, waitForStableMs > 0 {
            return waitForStablePTYLogOutput(tabID: tabID, lines: lines, waitForStableMs: waitForStableMs)
        }
        return encodedPTYLogOutput(tabID: tabID, lines: lines)
    }

    private func waitForStablePTYLogOutput(tabID: String, lines: Int, waitForStableMs: Int) -> String {
        let maxWaitMs = min(waitForStableMs, 30000)
        let stabilityThresholdMs = min(maxWaitMs, 500)
        let pollIntervalMs = 250
        let deadline = DispatchTime.now() + .milliseconds(maxWaitMs)
        var previousOutput: String?
        var stableSince: DispatchTime?
        var latestResponse = encodedPTYLogOutput(tabID: tabID, lines: lines)

        while DispatchTime.now() < deadline {
            latestResponse = encodedPTYLogOutput(tabID: tabID, lines: lines)
            guard let json = parseJSONObject(latestResponse),
                  json["error"] == nil else {
                return latestResponse
            }

            let currentOutput = json["output"] as? String ?? ""
            if currentOutput == previousOutput {
                if stableSince == nil { stableSince = DispatchTime.now() }
                if let stableSince {
                    let stableMs = Int((DispatchTime.now().uptimeNanoseconds - stableSince.uptimeNanoseconds) / 1_000_000)
                    if stableMs >= stabilityThresholdMs {
                        return latestResponse
                    }
                }
            } else {
                previousOutput = currentOutput
                stableSince = nil
            }

            Thread.sleep(forTimeInterval: Double(pollIntervalMs) / 1000.0)
        }

        return latestResponse
    }

    private func parseJSONObject(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private func encodedPTYLogOutput(tabID: String, lines: Int) -> String {
        let result: (path: String?, error: String?) = onMain {
            guard let (_, session) = self.resolveTab(tabID) else {
                return (nil, self.jsonError("Tab not found: \(tabID)"))
            }
            session.syncCurrentPTYLog()
            return (session.currentPTYLogPath(), nil)
        }
        if let error = result.error { return error }
        guard let path = result.path else {
            return jsonError("No PTY log available for tab \(tabID). The tab may not have run an AI tool.")
        }
        let outputTabID = canonicalControlPlaneTabID(tabID)

        guard let text = TelemetryRecorder.readPTYLogTail(path: path) else {
            return encodeAny(["tab_id": outputTabID, "output": "", "lines": 0, "source": "pty_log"])
        }

        let clampedLines = max(1, lines)
        var outputLines = text.components(separatedBy: "\n")
        if outputLines.count > clampedLines {
            outputLines = Array(outputLines.suffix(clampedLines))
        }

        var output = outputLines.joined(separator: "\n")
        if output.utf8.count > Self.maxOutputBytes {
            outputLines = Array(outputLines.suffix(max(1, clampedLines / 2)))
            output = outputLines.joined(separator: "\n")
        }

        return encodeAny([
            "tab_id": outputTabID,
            "output": output,
            "lines": outputLines.count,
            "source": "pty_log"
        ])
    }

    /// Formats buffer data into the standard tab_output response.
    private func formatBufferOutput(tabID: String, data: Data, lines: Int) -> String {
        let outputTabID = canonicalControlPlaneTabID(tabID)
        let text = String(decoding: data, as: UTF8.self)
        var outputLines = text.components(separatedBy: "\n")

        // Strip trailing empty lines (terminal buffer pads below cursor)
        while let last = outputLines.last,
              last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            outputLines.removeLast()
        }

        if outputLines.count > lines {
            outputLines = Array(outputLines.suffix(lines))
        }

        var output = outputLines.joined(separator: "\n")

        // Cap total size — re-slice and update outputLines so count stays accurate
        if output.utf8.count > Self.maxOutputBytes {
            outputLines = Array(outputLines.suffix(max(1, lines / 2)))
            output = outputLines.joined(separator: "\n")
        }

        return encodeAny([
            "tab_id": outputTabID,
            "output": output,
            "lines": outputLines.count,
            "source": "buffer"
        ])
    }

    private func submitSnapshot(for session: TerminalSessionModel) -> AISubmitSnapshot {
        let toolName = session.aiDisplayAppName
            ?? session.activeAppName
            ?? session.effectiveAIProvider
            ?? "shell"
        let transcript: String
        if let data = session.captureRemoteSnapshot(),
           !data.isEmpty {
            transcript = String(decoding: data, as: UTF8.self)
        } else {
            transcript = session.cachedRemoteOutputText
        }
        return AISubmitSnapshot(
            toolName: toolName,
            status: session.effectiveStatus.rawValue,
            isAtPrompt: session.effectiveIsAtPrompt,
            transcript: transcript
        )
    }

    /// Lightweight fingerprint of buffer content: (byteCount, SHA256 of last 4KB).
    /// Avoids retaining full buffer strings between stability polls.
    private static func bufferFingerprint(_ data: Data) -> (Int, Data) {
        let count = data.count
        let tailSize = min(count, 4096)
        let tail = data.suffix(tailSize)
        var hash = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
        tail.withUnsafeBytes { ptr in
            hash.withUnsafeMutableBytes { hashPtr in
                _ = CC_SHA256(ptr.baseAddress, CC_LONG(tail.count), hashPtr.bindMemory(to: UInt8.self).baseAddress)
            }
        }
        return (count, hash)
    }

    func setCTO(tabID: String, override overrideStr: String) -> String {
        onMain {
            guard let override = TabTokenOptOverride(rawValue: overrideStr) else {
                let valid = TabTokenOptOverride.allCases.map(\.rawValue).joined(separator: ", ")
                return self.jsonError("Invalid override value: \(overrideStr). Valid values: \(valid)")
            }

            guard let uuid = self.resolveControlPlaneTabIDLocked(tabID) else {
                return self.jsonError("Invalid tab ID: \(tabID)")
            }
            guard let model = self.modelForTab(uuid) else {
                return self.jsonError("Tab not found: \(tabID)")
            }
            guard let index = model.tabs.firstIndex(where: { $0.id == uuid }) else {
                return self.jsonError("Tab not found: \(tabID)")
            }

            let mode = FeatureSettings.shared.tokenOptimizationMode
            guard mode != .off else {
                return self.jsonError("Token optimization is globally disabled (mode=off). Enable it in settings first.")
            }

            model.tabs[index].tokenOptOverride = override
            model.tabs[index].session?.tokenOptOverride = override

            // Recalculate flag file and record decision
            if let sessionID = model.tabs[index].session?.tabIdentifier {
                let isAI = model.tabs[index].session?.activeAppName != nil
                let decision = CTOFlagManager.recalculate(
                    sessionID: sessionID,
                    mode: mode,
                    override: override,
                    isAIActive: isAI
                )
                CTORuntimeMonitor.shared.recordDecision(
                    sessionID: sessionID,
                    mode: mode,
                    override: override,
                    isAIActive: isAI,
                    previousState: decision.previousState,
                    nextState: decision.nextState,
                    changed: decision.changed,
                    reason: decisionReason(mode: mode, override: override, isAIActive: isAI),
                    trigger: .overrideChanged
                )
            }

            let tab = model.tabs[index]
            Log.info("MCP: setCTO tab \(tabID) override=\(overrideStr)")
            return self.encodeAny([
                "ok": true,
                "cto_active": tab.isTokenOptActive,
                "cto_override": tab.tokenOptOverride.rawValue
            ])
        }
    }

    // MARK: - Approval Response (from iOS)

    /// Called by RemoteControlManager when the iOS app responds to an approval request.
    func resolveApproval(requestID: String, approved: Bool) {
        let result: MCPApprovalResult = approved ? .allowedOnce : .denied
        approvalLock.lock()
        let handler = pendingApprovals.removeValue(forKey: requestID)
        pendingApprovalDetails.removeValue(forKey: requestID)
        approvalLock.unlock()
        handler?(result)
    }

    // MARK: - Runtime Integration

    /// Check if a tab is managed by the agent runtime.
    func isRuntimeManagedTab(_ tabID: UUID) -> Bool {
        RuntimeSessionManager.shared.isRuntimeManaged(tabID)
    }

    // MARK: - Tab Context

    /// Build an MCPTabContext from the current state of a tab. Must be called on main.
    private func gatherTabContext(_ tabID: String) -> MCPTabContext? {
        guard let (_, session) = resolveTab(tabID) else { return nil }
        return MCPTabContext(
            directory: session.currentDirectory,
            gitBranch: session.gitBranch,
            sshHost: nil,
            processes: session.processGroup?.children.map(\.name),
            environment: nil,
            shellPID: session.existingRustTerminalView?.shellPid
        )
    }

    // MARK: - Helpers

    /// Picks the single tab from `candidates` whose shell actually has a Claude
    /// process running, per the live OS process tree. Used by
    /// `RuntimeSessionManager` to disambiguate same-cwd tabs without permanently
    /// giving up when process-tree doesn't resolve (e.g. two tabs in Aethyme
    /// both running Claude — return nil and let a later event with a distinct
    /// session ID resolve them).
    func disambiguateClaudeTabsByProcessTree(candidates: [UUID]) -> UUID? {
        onMain {
            guard !candidates.isEmpty,
                  let snapshot = ProcessTreeProviderResolver.captureSnapshot()
            else { return nil }

            var matchingTabIDs: [UUID] = []
            for tabID in candidates {
                guard let session = self.findSession(for: tabID),
                      let shellPID = session.existingRustTerminalView?.shellPid,
                      shellPID > 0
                else { continue }
                let resolved = ProcessTreeProviderResolver.resolve(
                    shellPid: shellPID,
                    snapshot: snapshot
                )
                if resolved?.lowercased() == "claude" {
                    matchingTabIDs.append(tabID)
                }
            }
            return matchingTabIDs.count == 1 ? matchingTabIDs.first : nil
        }
    }

    private func findSession(for tabID: UUID) -> TerminalSessionModel? {
        for (_, model) in allModels {
            if let tab = model.tabs.first(where: { $0.id == tabID }),
               let session = tab.session {
                return session
            }
        }
        return nil
    }

    private func resolveTabIDLocked(for target: TabTarget, strictSession: Bool = false) -> UUID? {
        rebuildRoutingIndexIfNeededLocked()

        // Fast-path: stamped tabID from a trusted source.
        if let tabID = target.tabID,
           routingIndex.contains(tabID: tabID) {
            return tabID
        }

        // Session-id-driven resolution. Strict callers fail closed on
        // unmatched session; lenient callers fall through to first-event
        // binding by directory only when sessionID is absent.
        if target.sessionID != nil {
            let result = tabAttribution.resolve(target: target, policy: .requireSessionMatch)
            if case let .matched(tabID, _) = result {
                return tabID
            }
            // requireSessionMatch refused / ambiguous / noMatch — return nil
            // regardless of strictSession. The "loose" fallback path was the
            // leak vector closed by today's investigation.
            return nil
        }

        guard !strictSession else { return nil }

        // No sessionID hint: try to bind to an unbound tab in the directory.
        let bind = tabAttribution.resolve(target: target, policy: .bindUnboundByDirectory)
        if case let .matched(tabID, _) = bind {
            return tabID
        }
        return nil
    }

    private lazy var tabAttribution = TabAttribution {
        self.onMain { self.routingRecordsLocked() }
    }

    private func resolveTabLocked(for target: TabTarget, strictSession: Bool = false) -> OverlayTab? {
        guard let tabID = resolveTabIDLocked(for: target, strictSession: strictSession) else {
            return nil
        }
        return tabLocked(for: tabID)
    }

    private func tabLocked(for tabID: UUID) -> OverlayTab? {
        for (_, model) in allModels {
            if let tab = model.tabs.first(where: { $0.id == tabID }) {
                return tab
            }
        }
        return nil
    }

    private func learnSessionRouteLocked(target: TabTarget, tabID: UUID) {
        guard let routeKey = learnedSessionRouteKey(target: target),
              routingIndex.contains(tabID: tabID) else {
            return
        }
        learnedSessionRoutes[routeKey] = tabID
    }

    private func learnedSessionRouteKey(target: TabTarget) -> String? {
        guard let sessionID = TabRoutingIndex.normalizedSessionID(target.sessionID) else {
            return nil
        }
        let provider = AIResumeParser.normalizeProviderName(target.tool)
            ?? target.tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !provider.isEmpty else { return nil }
        return "\(provider)|\(sessionID)"
    }

    private func rebuildRoutingIndexIfNeededLocked() {
        guard routingIndexNeedsRebuild else { return }
        let validTabIDs = Set(allTabs.map(\.id))
        learnedSessionRoutes = learnedSessionRoutes.filter { validTabIDs.contains($0.value) }
        routingIndex = TabRoutingIndex(records: routingRecordsLocked())
        routingIndexNeedsRebuild = false
    }

    private func routingRecordsLocked() -> [TabRouteRecord] {
        var records: [TabRouteRecord] = []
        for (_, model) in allModels {
            for tab in model.tabs {
                records.append(contentsOf: liveRoutingRecordsLocked(for: tab))

                if let state = model.deferredRestoreStatesByTabID[tab.id]
                    ?? model.persistedRestoreFallbackStatesByTabID[tab.id] {
                    records.append(contentsOf: savedRoutingRecordsLocked(for: tab, state: state))
                }
            }
        }
        return records
    }

    private func liveRoutingRecordsLocked(for tab: OverlayTab) -> [TabRouteRecord] {
        let displaySession = tab.displaySession
        return tab.splitController.terminalSessions.map { paneID, session in
            TabRouteRecord(
                tabID: tab.id,
                paneID: paneID,
                title: tab.displayTitle,
                directory: session.currentDirectory,
                repoRoot: session.gitRootPath,
                provider: session.lastAIProvider,
                displayName: session.aiDisplayAppName,
                activeAppName: session.activeAppName,
                sessionID: session.normalizedStoredAISessionId(),
                lastActivity: session.lastActivityDate,
                isDisplaySession: session === displaySession
            )
        }
    }

    private func savedRoutingRecordsLocked(for tab: OverlayTab, state: SavedTabState) -> [TabRouteRecord] {
        var records: [TabRouteRecord] = []
        let topLevelProvider = AIResumeParser.normalizeProviderName(state.aiProvider ?? "")
        let topLevelSessionID = TabRoutingIndex.normalizedSessionID(state.aiSessionId)
        if topLevelProvider != nil || topLevelSessionID != nil {
            records.append(TabRouteRecord(
                tabID: tab.id,
                title: tab.displayTitle,
                directory: state.directory,
                repoRoot: state.knownRepoRoot ?? state.repoGroupID,
                provider: topLevelProvider,
                displayName: displayNameLocked(provider: topLevelProvider),
                sessionID: topLevelSessionID,
                lastActivity: maxDate(state.lastInputAt, state.lastExitAt, state.agentStartedAt)
            ))
        }

        for paneState in state.paneStates ?? [] {
            let provider = AIResumeParser.normalizeProviderName(paneState.aiProvider ?? "")
            let sessionID = TabRoutingIndex.normalizedSessionID(paneState.aiSessionId)
            guard provider != nil || sessionID != nil else { continue }
            records.append(TabRouteRecord(
                tabID: tab.id,
                paneID: UUID(uuidString: paneState.paneID),
                title: tab.displayTitle,
                directory: paneState.directory,
                repoRoot: paneState.knownRepoRoot,
                provider: provider,
                displayName: displayNameLocked(provider: provider),
                sessionID: sessionID,
                lastActivity: maxDate(
                    paneState.lastInputAt,
                    paneState.lastOutputAt,
                    paneState.agentStartedAt,
                    paneState.lastExitAt
                )
            ))
        }
        return records
    }

    private func displayNameLocked(provider: String?) -> String? {
        guard let provider else { return nil }
        return AIToolRegistry.allTools.first { $0.resumeProviderKey == provider }?.displayName
            ?? provider.capitalized
    }

    private func maxDate(_ dates: Date?...) -> Date {
        dates.compactMap { $0 }.max() ?? .distantPast
    }

    private func historyAdoptionSession(
        in tab: OverlayTab,
        request: HistorySessionAdoptionRequest
    ) -> TerminalSessionModel? {
        let displaySession = tab.displaySession
        let ranked: [(
            session: TerminalSessionModel,
            exactRank: Int,
            directoryRank: Int,
            focusRank: Int,
            activity: Date
        )] = tab.splitController.terminalSessions.compactMap { _, session in
            let storedSessionId = session.normalizedStoredAISessionId()
            let directoryRank = historyAdoptionDirectoryRank(session: session, directory: request.directory)
            guard canAdoptHistorySession(
                session,
                request: request,
                storedSessionId: storedSessionId,
                directoryRank: directoryRank
            ) else {
                return nil
            }

            return (
                session: session,
                exactRank: storedSessionId == request.sessionId ? 0 : 1,
                directoryRank: directoryRank ?? Int.max,
                focusRank: session === displaySession ? 0 : 1,
                activity: session.lastActivityDate
            )
        }

        return ranked.min { lhs, rhs in
            if lhs.exactRank != rhs.exactRank {
                return lhs.exactRank < rhs.exactRank
            }
            if lhs.directoryRank != rhs.directoryRank {
                return lhs.directoryRank < rhs.directoryRank
            }
            if lhs.focusRank != rhs.focusRank {
                return lhs.focusRank < rhs.focusRank
            }
            return lhs.activity > rhs.activity
        }?.session
    }

    private func canAdoptHistorySession(
        _ session: TerminalSessionModel,
        request: HistorySessionAdoptionRequest,
        storedSessionId: String?,
        directoryRank: Int?
    ) -> Bool {
        let existingProvider = AIResumeParser.normalizeProviderName(session.aiDisplayAppName ?? "")
            ?? AIResumeParser.normalizeProviderName(session.effectiveAIProvider ?? "")
            ?? AIResumeParser.normalizeProviderName(session.lastAIProvider ?? "")
        if let existingProvider, existingProvider != request.providerKey {
            return false
        }

        if storedSessionId == request.sessionId {
            return true
        }

        guard request.canReplaceDifferentStoredSession else {
            return false
        }

        guard directoryRank != nil else {
            return false
        }

        if session.lastAISessionIdentitySource == .observed,
           let currentObservedAt = session.agentStartedAt,
           request.observedAt < currentObservedAt {
            return false
        }

        guard storedSessionId != nil else {
            return true
        }

        switch session.lastAISessionIdentitySource {
        case .synthetic, .observed:
            return true
        case .explicit:
            return existingProvider == request.providerKey
        case nil:
            return existingProvider == request.providerKey
        }
    }

    private func historyAdoptionDirectoryRank(session: TerminalSessionModel, directory: String?) -> Int? {
        guard let directory,
              !directory.isEmpty else {
            return nil
        }
        return DirectoryPathMatcher.bidirectionalPrefixRank(
            targetPath: directory,
            candidatePath: session.currentDirectory
        )
    }

    /// Returns true if a matching tab running the named tool is currently at prompt.
    /// When sessionID is provided, only that specific AI session suppresses completion events.
    func isToolAtPrompt(toolName: String, sessionID: String? = nil) -> Bool {
        let lowered = toolName.lowercased()
        for (_, model) in allModels {
            for tab in model.tabs {
                guard let session = tab.session else { continue }
                let matches = session.aiDisplayAppName?.lowercased() == lowered
                    || session.activeAppName?.lowercased() == lowered
                guard matches else { continue }
                if let sessionID, session.effectiveAISessionId != sessionID {
                    continue
                }
                if session.effectiveIsAtPrompt { return true }
            }
        }
        return false
    }

    func renameTab(tabID: String, title: String) -> String {
        onMain {
            guard let uuid = self.resolveControlPlaneTabIDLocked(tabID) else {
                return self.jsonError("Invalid tab ID: \(tabID)")
            }
            guard let model = self.modelForTab(uuid) else {
                return self.jsonError("Tab not found: \(tabID)")
            }
            guard let index = model.tabs.firstIndex(where: { $0.id == uuid }) else {
                return self.jsonError("Tab not found: \(tabID)")
            }

            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            model.tabs[index].customTitle = trimmed.isEmpty ? nil : trimmed
            for (_, session) in model.tabs[index].splitController.terminalSessions {
                session.tabTitleOverride = model.tabs[index].customTitle
            }
            // With @Observable, tabs[index] mutation auto-triggers SwiftUI updates.

            return self.encodeAny([
                "ok": true,
                "title": model.tabs[index].customTitle ?? ""
            ])
        }
    }

    // MARK: - Repo Metadata

    func getRepoMetadata(repoPath: String) -> String {
        let model = RepositoryCache.shared.cachedModel(forRoot: repoPath)
        let metadata = model?.metadata ?? RepoMetadataStore.load(repoRoot: repoPath)
        let frequentCmds = PersistentHistoryStore.shared
            .frequentCommandsForRepo(repoRoot: repoPath, limit: 10)

        var result: [String: Any] = [
            "repo_path": repoPath,
            "repo_name": URL(fileURLWithPath: repoPath).lastPathComponent
        ]
        if let desc = metadata.description { result["description"] = desc }
        if !metadata.labels.isEmpty { result["labels"] = metadata.labels }
        if !metadata.favoriteFiles.isEmpty { result["favorite_files"] = metadata.favoriteFiles }
        if let updated = metadata.updatedAt {
            result["updated_at"] = ISO8601DateFormatter().string(from: updated)
        }
        if !frequentCmds.isEmpty {
            result["frequent_commands"] = frequentCmds.map { cmd in
                [
                    "command": cmd.command,
                    "count": cmd.count,
                    "last_used": ISO8601DateFormatter().string(from: cmd.lastUsed),
                    "frecency_score": cmd.frecencyScore
                ] as [String: Any]
            }
        }

        // Aggregated stats from history.db + runs.db
        let stats = RepoStatsProvider.stats(for: repoPath)
        let iso = ISO8601DateFormatter()
        var statsDict: [String: Any] = [
            "total_commands": stats.totalCommands,
            "successful_commands": stats.successfulCommands,
            "failed_commands": stats.failedCommands,
            "success_rate": stats.successRate,
            "avg_command_duration": stats.averageCommandDuration,
            "total_runs": stats.totalRuns,
            "total_tokens": stats.totalTokens,
            "total_cost": stats.totalCost,
            "total_turns": stats.totalTurns,
            "providers": stats.providers
        ]
        if !stats.topTools.isEmpty {
            statsDict["top_tools"] = stats.topTools.map { [
                "tool": $0.tool, "count": $0.count
            ] as [String: Any] }
        }
        if let lastCmd = stats.lastCommandAt { statsDict["last_command_at"] = iso.string(from: lastCmd) }
        if let lastRun = stats.lastRunAt { statsDict["last_run_at"] = iso.string(from: lastRun) }
        result["stats"] = statsDict

        return encodeAny(result)
    }

    func setRepoMetadata(
        repoPath: String,
        description: String?,
        labels: [String]?,
        favoriteFiles: [String]?
    ) -> String {
        if let model = RepositoryCache.shared.cachedModel(forRoot: repoPath) {
            return onMain {
                var updated = model.metadata
                if let desc = description { updated.description = desc.isEmpty ? nil : desc }
                if let labels { updated.labels = labels }
                if let files = favoriteFiles { updated.favoriteFiles = files }
                model.updateMetadata(updated)
                return self.encodeAny(["ok": true])
            }
        } else {
            var metadata = RepoMetadataStore.load(repoRoot: repoPath)
            if let desc = description { metadata.description = desc.isEmpty ? nil : desc }
            if let labels { metadata.labels = labels }
            if let files = favoriteFiles { metadata.favoriteFiles = files }
            metadata.updatedAt = Date()
            RepoMetadataStore.save(metadata, repoRoot: repoPath)
            return encodeAny(["ok": true])
        }
    }

    func repoFrequentCommands(repoPath: String, limit: Int) -> String {
        let cmds = PersistentHistoryStore.shared
            .frequentCommandsForRepo(repoRoot: repoPath, limit: limit)
        let result = cmds.map { cmd in
            [
                "command": cmd.command,
                "count": cmd.count,
                "last_used": ISO8601DateFormatter().string(from: cmd.lastUsed),
                "frecency_score": cmd.frecencyScore
            ] as [String: Any]
        }
        return encodeAny(result)
    }

    func repoGetEvents(
        repoPath: String,
        limit: Int,
        tabID: String? = nil,
        eventTypes: [String]? = nil,
        tool: String? = nil,
        producer: String? = nil,
        sessionID: String? = nil,
        truncateMessages: Bool = true
    ) -> String {
        // Check the per-repo event buffer in AppModel (populated on event ingestion)
        let events: [AIEvent]
        if let appModel = allModels.first?.model.appModel {
            let requestedTypes = Set((eventTypes ?? []).map { $0.lowercased() }.filter { !$0.isEmpty })
            let normalizedTool = tool?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let normalizedProducer = producer?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let normalizedSessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedTabID = tabID?.trimmingCharacters(in: .whitespacesAndNewlines)

            let filtered = (appModel.eventsByRepo[repoPath] ?? []).filter { event in
                if let normalizedTabID,
                   let eventTabID = event.tabID,
                   controlPlaneTabID(for: eventTabID) != normalizedTabID {
                    return false
                } else if normalizedTabID != nil, event.tabID == nil {
                    return false
                }

                if !requestedTypes.isEmpty, !requestedTypes.contains(event.type.lowercased()) {
                    return false
                }
                if let normalizedTool, event.tool.lowercased() != normalizedTool {
                    return false
                }
                if let normalizedProducer,
                   event.producer?.lowercased() != normalizedProducer {
                    return false
                }
                if let normalizedSessionID,
                   event.sessionID != normalizedSessionID {
                    return false
                }
                return true
            }

            events = Array(filtered.suffix(limit))
        } else {
            events = []
        }
        let result: [[String: Any]] = events.map { event in
            let message = truncateMessages ? String(event.message.prefix(200)) : event.message
            var entry: [String: Any] = [
                "id": event.id.uuidString,
                "source": event.source.rawValue,
                "type": event.type,
                "tool": event.tool,
                "message": message,
                "ts": event.ts
            ]
            if let dir = event.directory { entry["directory"] = dir }
            if let tab = event.tabID { entry["tab_id"] = self.controlPlaneTabID(for: tab) }
            if let session = event.sessionID { entry["session_id"] = session }
            if let producer = event.producer { entry["producer"] = producer }
            entry["reliability"] = event.reliability.rawValue
            return entry
        }
        return encodeAny(["repo_path": repoPath, "count": result.count, "events": result])
    }

    func activeRunSummary(forOverlayTabID tabID: UUID) -> [String: Any]? {
        onMain {
            guard let tab = self.allTabs.first(where: { $0.id == tabID }),
                  let session = tab.displaySession ?? tab.session,
                  let run = TelemetryRecorder.shared.activeRunForTab(session.tabIdentifier) else {
                return nil
            }

            var result: [String: Any] = [
                "run_id": run.id,
                "provider": run.provider,
                "started_at": TelemetryStore.isoString(from: run.startedAt),
                "metadata": run.metadata,
                "duration_so_far_ms": Int(Date().timeIntervalSince(run.startedAt) * 1000)
            ]
            if let sessionID = run.sessionID {
                result["session_id"] = sessionID
            }
            if let parentRunID = run.parentRunID {
                result["parent_run_id"] = parentRunID
            }
            return result
        }
    }

    func runtimeLaunchSnapshot(forOverlayTabID tabID: UUID) -> RuntimeLaunchReadinessSnapshot? {
        onMain {
            guard let tab = self.allTabs.first(where: { $0.id == tabID }),
                  let session = tab.displaySession ?? tab.session else {
                return nil
            }
            return RuntimeLaunchReadinessSnapshot(
                shellLoading: session.isShellLoading,
                isAtPrompt: session.effectiveIsAtPrompt,
                effectiveStatus: session.effectiveStatus.rawValue,
                rawStatus: session.status.rawValue,
                activeApp: session.aiDisplayAppName ?? session.activeAppName,
                rawActiveApp: session.activeAppName,
                aiProvider: session.effectiveAIProvider,
                activeRunProvider: TelemetryRecorder.shared.activeRunForTab(session.tabIdentifier)?.provider,
                processNames: session.processGroup?.children.map(\.name) ?? []
            )
        }
    }

    /// Find the OverlayTabsModel that owns a given tab UUID.
    private func modelForTab(_ uuid: UUID) -> OverlayTabsModel? {
        allModels.first(where: { $0.model.tabs.contains(where: { $0.id == uuid }) })?.model
    }

    private func resolveTab(_ tabID: String) -> (OverlayTab, TerminalSessionModel)? {
        guard let uuid = resolveControlPlaneTabIDLocked(tabID) else { return nil }
        for (_, model) in allModels {
            if let tab = model.tabs.first(where: { $0.id == uuid }),
               let session = tab.displaySession ?? tab.session {
                return (tab, session)
            }
        }
        return nil
    }

    private func tabSummary(_ tab: OverlayTab) -> [String: Any] {
        let session = tab.displaySession ?? tab.session
        var result: [String: Any] = [
            "tab_id": controlPlaneTabIDLocked(for: tab.id),
            "title": tab.displayTitle,
            "status": session?.effectiveStatus.rawValue ?? session?.status.rawValue ?? "unknown",
            "cwd": session?.currentDirectory ?? "",
            "is_at_prompt": session?.effectiveIsAtPrompt ?? session?.isAtPrompt ?? false,
            "is_mcp_controlled": tab.isMCPControlled,
            "cto_active": tab.isTokenOptActive,
            "cto_override": tab.tokenOptOverride.rawValue
        ]
        if let rawStatus = session?.status.rawValue {
            result["raw_status"] = rawStatus
        }
        if let rawPrompt = session?.isAtPrompt {
            result["raw_is_at_prompt"] = rawPrompt
        }
        if let app = session?.aiDisplayAppName ?? session?.activeAppName {
            result["active_app"] = app
        }
        if let rawApp = session?.activeAppName {
            result["raw_active_app"] = rawApp
        }
        if let aiProvider = session?.effectiveAIProvider {
            result["ai_provider"] = aiProvider
        }
        if let aiSessionID = session?.effectiveAISessionId {
            result["ai_session_id"] = aiSessionID
        }
        if let branch = session?.gitBranch {
            result["git_branch"] = branch
        }
        if let repoModel = session?.repositoryModel {
            result["repo_root"] = repoModel.rootPath
            if let desc = repoModel.metadata.description {
                result["repo_description"] = desc
            }
            if !repoModel.metadata.labels.isEmpty {
                result["repo_labels"] = repoModel.metadata.labels
            }
        }
        return result
    }

    private func tabExecutionReadiness(for session: TerminalSessionModel?) -> TabExecutionReadiness {
        TabExecutionReadiness.evaluate(
            snapshot: TabExecutionReadinessSnapshot(
                shellLoading: session?.isShellLoading ?? true,
                isAtPrompt: session?.isAtPrompt ?? false,
                hasView: session?.existingRustTerminalView != nil,
                status: session?.status.rawValue ?? "unknown"
            )
        )
    }

    private func addExecutionReadinessFields(to result: inout [String: Any], session: TerminalSessionModel?) {
        let readiness = tabExecutionReadiness(for: session)
        result["shell_loading"] = session?.isShellLoading ?? true
        result["has_terminal_view"] = session?.existingRustTerminalView != nil
        result["can_accept_exec"] = readiness.canAcceptExec
        result["exec_acceptance_mode"] = readiness.acceptanceMode.rawValue
        result["ready_for_exec"] = readiness.isReady
        result["readiness_reason"] = readiness.reason.rawValue
    }

    private func tabReadinessSnapshot(tabID: String) -> [String: Any]? {
        guard let (tab, session) = resolveTab(tabID) else {
            return nil
        }
        var result = tabSummary(tab)
        addExecutionReadinessFields(to: &result, session: session)
        return result
    }

    private func aiEventDictionary(_ event: AIEvent) -> [String: Any] {
        [
            "id": event.id.uuidString,
            "timestamp": event.ts,
            "type": event.type,
            "tool": event.tool,
            "message": event.message,
            "source": event.source.rawValue,
            "tab_id": event.tabID.map(controlPlaneTabID) as Any,
            "session_id": event.sessionID as Any,
            "repo_path": event.repoPath as Any,
            "producer": event.producer as Any,
            "notification_type": event.notificationType as Any,
            "reliability": event.reliability.rawValue
        ].compactMapValues { $0 }
    }

    func controlPlaneTabID(for nativeTabID: UUID) -> String {
        onMain {
            self.controlPlaneTabIDLocked(for: nativeTabID)
        }
    }

    func resolveControlPlaneTabID(_ tabID: String) -> UUID? {
        onMain {
            self.resolveControlPlaneTabIDLocked(tabID)
        }
    }

    private func canonicalControlPlaneTabID(_ tabID: String) -> String {
        onMain {
            guard let nativeTabID = self.resolveControlPlaneTabIDLocked(tabID) else {
                return tabID
            }
            return self.controlPlaneTabIDLocked(for: nativeTabID)
        }
    }

    private func controlPlaneTabIDLocked(for nativeTabID: UUID) -> String {
        pruneTabAliasesLocked()
        if let existingID = mcpTabIDs.id(for: nativeTabID) {
            return existingID
        }
        guard allTabs.contains(where: { $0.id == nativeTabID }) else {
            return nativeTabID.uuidString
        }
        return mcpTabIDs.assignID(for: nativeTabID)
    }

    private func resolveControlPlaneTabIDLocked(_ tabID: String) -> UUID? {
        pruneTabAliasesLocked()
        if let nativeTabID = mcpTabIDs.nativeTabID(for: tabID) {
            return nativeTabID
        }
        return UUID(uuidString: tabID)
    }

    private func pruneTabAliasesLocked() {
        mcpTabIDs.prune(validTabIDs: Set(allTabs.map(\.id)))
    }

    private func preferredModelEntry(from models: [(windowID: Int, model: OverlayTabsModel)]) -> (windowID: Int, model: OverlayTabsModel)? {
        if let activeModel = activeOverlayModelProvider?(),
           let entry = models.first(where: { $0.model === activeModel }) {
            return entry
        }

        if let appDelegate = NSApp.delegate as? AppDelegate,
           let activeModel = MainActor.assumeIsolated({ appDelegate.activeOverlayModel }),
           let entry = models.first(where: { $0.model === activeModel }) {
            return entry
        }

        return models.first
    }

    /// Dispatch to main thread and return result. Safe from any background queue.
    private func onMain<T>(_ block: @escaping () -> T) -> T {
        if Thread.isMainThread { return block() }
        return DispatchQueue.main.sync { block() }
    }

    /// Dispatch to the main actor and return result.
    private func onMainActor<T>(_ block: @MainActor @escaping () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated(block)
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated(block)
        }
    }

    /// Show a modal approval dialog for tab creation. Must be called on main thread.
    private func requestApproval(message: String) -> Bool {
        Chau7ObservabilityService.shared.recordEvent(
            type: "approval_waiting",
            subsystem: "mcp_approvals",
            detail: ["kind": "tab_request"]
        )
        let alert = NSAlert()
        alert.messageText = L("mcp.approval.tabRequest.title", "MCP Tab Request")
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: L("mcp.approval.allow", "Allow"))
        alert.addButton(withTitle: L("mcp.approval.deny", "Deny"))
        let approved = alert.runModal() == .alertFirstButtonReturn
        Chau7ObservabilityService.shared.recordEvent(
            type: "approval_resolved",
            subsystem: "mcp_approvals",
            detail: [
                "kind": "tab_request",
                "decision": approved ? "approved" : "denied"
            ]
        )
        return approved
    }

    /// Dual-path command approval: shows a three-option NSAlert on Mac AND sends
    /// request to iOS. First response (Mac or iOS) wins. Must be called on main thread.
    private func requestCommandApproval(command: String, flaggedCommand: String, reason: String, permissions: ResolvedPermissions) -> MCPApprovalResult {
        let requestID = UUID().uuidString
        let sourceInfo = permissions.matchedProfile != nil
            ? "Permissions source: profile \"\(permissions.matchedProfile!.name)\""
            : "Permissions source: global settings"
        let contextNote = "\(reason)\n\n\(sourceInfo)"
        Chau7ObservabilityService.shared.recordEvent(
            type: "approval_waiting",
            subsystem: "mcp_approvals",
            sessionID: requestID,
            detail: [
                "kind": "command_request",
                "flagged_command": flaggedCommand,
                "reason": reason,
                "permissions_source": permissions.sourceName
            ]
        )

        // Send approval request to iOS via RemoteControlManager
        let payload = ApprovalRequestPayload(
            requestID: requestID,
            command: command,
            flaggedCommand: flaggedCommand,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            tabTitle: nil,
            toolName: nil,
            projectName: nil,
            branchName: nil,
            currentDirectory: nil,
            recentCommand: nil,
            contextNote: contextNote,
            sessionID: nil
        )
        if let data = try? JSONEncoder().encode(payload) {
            onMainActor {
                RemoteControlManager.shared.sendApprovalRequest(requestID: requestID, payload: data)
            }
        }

        // Show local alert with three options
        let alert = NSAlert()
        alert.messageText = L("mcp.approval.commandTitle", "MCP Command Approval")
        alert.informativeText = String(format: L("mcp.approval.commandMessage", "An MCP client wants to execute:\n\n%@\n\n%@"), command, contextNote)
        alert.alertStyle = .warning

        // Buttons: Deny (default, safest), Allow Once, Always Allow
        alert.addButton(withTitle: L("mcp.approval.deny", "Deny"))
        alert.addButton(withTitle: L("mcp.approval.allowOnce", "Allow Once"))
        alert.addButton(withTitle: L("mcp.approval.alwaysAllow", "Always Allow"))

        // Register a handler so iOS response can dismiss the alert
        var iosResult: MCPApprovalResult?
        approvalLock.lock()
        pendingApprovalDetails[requestID] = [
            "request_id": requestID,
            "kind": "command_request",
            "flagged_command": flaggedCommand,
            "reason": reason,
            "permissions_source": permissions.sourceName,
            "requested_at": ISO8601DateFormatter().string(from: Date())
        ]
        pendingApprovals[requestID] = { result in
            iosResult = result
            // Dismiss the Mac alert from iOS response
            DispatchQueue.main.async {
                let code: NSApplication.ModalResponse = result == .denied ? .alertFirstButtonReturn : .alertSecondButtonReturn
                NSApp.stopModal(withCode: code)
            }
        }
        approvalLock.unlock()

        let response = alert.runModal()

        // Clean up pending handler if Mac user responded first
        approvalLock.lock()
        pendingApprovals.removeValue(forKey: requestID)
        pendingApprovalDetails.removeValue(forKey: requestID)
        approvalLock.unlock()

        let result: MCPApprovalResult
        if let iosResult {
            result = iosResult
        } else {
            switch response {
            case .alertFirstButtonReturn:
                result = .denied
            case .alertSecondButtonReturn:
                result = .allowedOnce
            case .alertThirdButtonReturn:
                result = .alwaysAllow
            default:
                result = .denied
            }
        }
        Chau7ObservabilityService.shared.recordEvent(
            type: "approval_resolved",
            subsystem: "mcp_approvals",
            sessionID: requestID,
            detail: [
                "kind": "command_request",
                "decision": approvalDecisionLabel(result),
                "flagged_command": flaggedCommand
            ]
        )
        return result
    }

    private func approvalDecisionLabel(_ result: MCPApprovalResult) -> String {
        switch result {
        case .denied:
            return "denied"
        case .allowedOnce:
            return "allowed_once"
        case .alwaysAllow:
            return "always_allow"
        }
    }

    /// Returns an error string if the verdict blocks/denies execution, nil if allowed.
    private func enforceVerdict(
        _ verdict: MCPCommandVerdict,
        permissions: ResolvedPermissions,
        fullInput: String,
        context: String
    ) -> String? {
        switch verdict {
        case .allowed:
            return nil
        case .blocked(let cmd, let reason):
            Log.info("MCP: blocked '\(cmd)' in \(context) (\(reason))")
            return jsonError("Command '\(cmd)' was blocked: \(reason).")
        case .needsApproval(let cmd, let reason):
            let result = onMain {
                self.requestCommandApproval(command: fullInput, flaggedCommand: cmd, reason: reason, permissions: permissions)
            }
            switch result {
            case .denied:
                Log.info("MCP: user denied '\(cmd)' in \(context)")
                return jsonError("Command '\(cmd)' was denied by user.")
            case .allowedOnce:
                Log.info("MCP: user allowed once '\(cmd)' in \(context)")
                return nil
            case .alwaysAllow:
                Log.info("MCP: user always-allowed '\(cmd)' in \(context) (\(permissions.sourceName))")
                FeatureSettings.shared.addToAllowedCommands(cmd, profileID: permissions.profileID)
                return nil
            }
        }
    }

    private func noWindowError() -> String {
        jsonError("No active Chau7 window")
    }

    private func jsonError(_ message: String) -> String {
        "{\"error\":\"\(message.replacingOccurrences(of: "\"", with: "\\\""))\"}"
    }

    private func encodeAny(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}
