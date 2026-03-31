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
/// to avoid deadlocking: the onInput callback chain re-enters Rust FFI
/// (isPtyEchoDisabled → pty_handle.lock()), which deadlocks if the Rust poll
/// thread concurrently holds that lock for PtyWrite event processing.
final class TerminalControlService {
    static let shared = TerminalControlService()

    /// Weak wrapper with a stable ID so window_id doesn't shift when models deallocate.
    private struct WeakModel {
        let windowID: Int
        weak var model: OverlayTabsModel?
    }

    private var registeredModels: [WeakModel] = []
    private var nextWindowID = 0

    /// Hard ceiling — even if the user sets a higher value in settings.
    private static let absoluteMaxTabs = 50

    /// Maximum output size returned by tab_output (512 KB).
    private static let maxOutputBytes = 512 * 1024

    // MARK: - Pending Approvals

    /// Tracks in-flight approval requests so iOS responses can resolve them.
    private var pendingApprovals: [String: (MCPApprovalResult) -> Void] = [:]
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
    }

    /// Unregister when a window closes. Optional — dead refs are pruned lazily.
    func unregister(_ model: OverlayTabsModel) {
        registeredModels.removeAll { $0.model == nil || $0.model === model }
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

    /// Apply a notification style to a tab found by target across ALL windows.
    @discardableResult
    func applyNotificationStyleAcrossWindows(for target: TabTarget, stylePreset: String, config: [String: String]) -> UUID? {
        for (_, model) in allModels {
            if let tabID = model.applyNotificationStyle(for: target, stylePreset: stylePreset, config: config) {
                return tabID
            }
        }
        return nil
    }

    // MARK: - Tab Operations

    func listTabs() -> String {
        onMain {
            let models = self.allModels
            guard !models.isEmpty else { return self.noWindowError() }
            var result: [[String: Any]] = []
            for (windowID, model) in models {
                for tab in model.tabs {
                    var summary = self.tabSummary(tab)
                    summary["window_id"] = windowID
                    result.append(summary)
                }
            }
            return self.encodeAny(result)
        }
    }

    func createTab(directory: String?, windowID: Int?) -> String {
        onMain {
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
                model = models[0].model
                resolvedWindowID = models[0].windowID
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
                "tab_id": tab.id.uuidString,
                "window_id": resolvedWindowID,
                "status": "created",
                "shell_loading": tab.session?.isShellLoading ?? true
            ])
        }
    }

    func execInTab(tabID: String, command: String) -> String {
        let context = onMain { self.gatherTabContext(tabID) }
        let (verdict, permissions) = MCPCommandFilter.check(command, context: context)
        if let err = enforceVerdict(verdict, permissions: permissions, fullInput: command, context: "tab \(tabID)") {
            return err
        }

        // Validate tab existence and prompt state synchronously on main,
        // but send the actual input asynchronously to avoid deadlocking
        // the main thread. The Rust terminal's sendInput → onInput callback
        // chain can re-enter pty_handle.lock() (via isPtyEchoDisabled),
        // which deadlocks if the poll thread holds that lock concurrently.
        let validationResult: (isValid: Bool, error: String?, isLoading: Bool, isAtPrompt: Bool) = onMain {
            guard let (_, session) = self.resolveTab(tabID) else {
                return (false, self.jsonError("Tab not found: \(tabID)"), false, false)
            }
            return (true, nil, session.isShellLoading, session.isAtPrompt)
        }

        guard validationResult.isValid else {
            return validationResult.error!
        }

        if validationResult.isLoading {
            DispatchQueue.main.async {
                guard let (_, session) = self.resolveTab(tabID) else { return }
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

            // Shell readiness
            result["shell_loading"] = session.isShellLoading

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

    func sendInput(tabID: String, input: String) -> String {
        let context = onMain { self.gatherTabContext(tabID) }
        let (verdict, permissions) = MCPCommandFilter.checkRawInput(input, context: context)
        if let err = enforceVerdict(verdict, permissions: permissions, fullInput: input, context: "tab \(tabID)") {
            return err
        }

        // Validate tab existence synchronously, send input asynchronously.
        // Same deadlock avoidance as execInTab — sendInput triggers the
        // same onInput → handleInputLine → isPtyEchoDisabled → pty_handle.lock() chain.
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
        pressKey(tabID: tabID, key: "enter", modifiers: [])
    }

    func closeTab(tabID: String, force: Bool) -> String {
        onMain {
            guard let uuid = UUID(uuidString: tabID) else {
                return self.jsonError("Invalid tab ID: \(tabID)")
            }
            guard let model = self.modelForTab(uuid) else {
                return self.jsonError("Tab not found: \(tabID)")
            }

            if !force {
                if let (_, session) = self.resolveTab(tabID),
                   session.status == .running || session.status == .waitingForInput {
                    return self.jsonError("Tab has a running process (status: \(session.status.rawValue)). Use force=true to close anyway.")
                }
            }

            Log.info("MCP: closing tab \(tabID) force=\(force)")
            model.closeTab(id: uuid, skipWarning: true)
            return self.encodeAny(["ok": true])
        }
    }

    func tabOutput(tabID: String, lines: Int, waitForStableMs: Int? = nil, source: String? = nil) -> String {
        // source=pty_log: return ANSI-stripped PTY log instead of terminal buffer.
        // Works for all AI tools regardless of alternate screen usage.
        if source == "pty_log" {
            return ptyLogOutput(tabID: tabID, lines: lines)
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
            guard let (_, session) = self.resolveTab(tabID) else {
                return self.jsonError("Tab not found: \(tabID)")
            }

            let clampedLines = max(1, lines)

            guard let data = session.captureRemoteSnapshot() else {
                return self.encodeAny(["tab_id": tabID, "output": "", "lines": 0])
            }

            return self.formatBufferOutput(tabID: tabID, data: data, lines: clampedLines)
        }
    }

    /// Returns the ANSI-stripped PTY log output for an AI session in a tab.
    /// This captures everything written to the terminal including alternate-screen
    /// content that TUI-based AI tools discard on exit.
    private func ptyLogOutput(tabID: String, lines: Int) -> String {
        let result: (path: String?, error: String?) = onMain {
            guard let (_, session) = self.resolveTab(tabID) else {
                return (nil, self.jsonError("Tab not found: \(tabID)"))
            }
            return (session.lastPTYLogPath, nil)
        }
        if let error = result.error { return error }
        guard let path = result.path else {
            return jsonError("No PTY log available for tab \(tabID). The tab may not have run an AI tool.")
        }

        guard let text = TelemetryRecorder.readPTYLogTail(path: path) else {
            return encodeAny(["tab_id": tabID, "output": "", "lines": 0, "source": "pty_log"])
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
            "tab_id": tabID,
            "output": output,
            "lines": outputLines.count,
            "source": "pty_log"
        ])
    }

    /// Formats buffer data into the standard tab_output response.
    private func formatBufferOutput(tabID: String, data: Data, lines: Int) -> String {
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
            "tab_id": tabID,
            "output": output,
            "lines": outputLines.count,
            "source": "buffer"
        ])
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

            guard let uuid = UUID(uuidString: tabID) else {
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
                    reason: decisionReason(mode: mode, override: override, isAIActive: isAI)
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
            environment: nil
        )
    }

    // MARK: - Helpers

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
            guard let uuid = UUID(uuidString: tabID) else {
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
            model.objectWillChange.send()

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

    /// Find the OverlayTabsModel that owns a given tab UUID.
    private func modelForTab(_ uuid: UUID) -> OverlayTabsModel? {
        allModels.first(where: { $0.model.tabs.contains(where: { $0.id == uuid }) })?.model
    }

    private func resolveTab(_ tabID: String) -> (OverlayTab, TerminalSessionModel)? {
        guard let uuid = UUID(uuidString: tabID) else { return nil }
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
            "tab_id": tab.id.uuidString,
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
        let alert = NSAlert()
        alert.messageText = "MCP Tab Request"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Dual-path command approval: shows a three-option NSAlert on Mac AND sends
    /// request to iOS. First response (Mac or iOS) wins. Must be called on main thread.
    private func requestCommandApproval(command: String, flaggedCommand: String, permissions: ResolvedPermissions) -> MCPApprovalResult {
        let requestID = UUID().uuidString
        let sourceInfo = permissions.matchedProfile != nil
            ? "Permissions source: profile \"\(permissions.matchedProfile!.name)\""
            : "Permissions source: global settings"

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
            contextNote: sourceInfo,
            sessionID: nil
        )
        if let data = try? JSONEncoder().encode(payload) {
            onMainActor {
                RemoteControlManager.shared.sendApprovalRequest(requestID: requestID, payload: data)
            }
        }

        // Show local alert with three options
        let alert = NSAlert()
        alert.messageText = "MCP Command Approval"
        alert.informativeText = "An MCP client wants to execute:\n\n\(command)\n\n\(sourceInfo)"
        alert.alertStyle = .warning

        // Buttons: Deny (default, safest), Allow Once, Always Allow
        alert.addButton(withTitle: "Deny")
        alert.addButton(withTitle: "Allow Once")
        alert.addButton(withTitle: "Always Allow")

        // Register a handler so iOS response can dismiss the alert
        var iosResult: MCPApprovalResult?
        approvalLock.lock()
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
        approvalLock.unlock()

        if let iosResult = iosResult {
            return iosResult
        }

        switch response {
        case .alertFirstButtonReturn:
            return .denied
        case .alertSecondButtonReturn:
            return .allowedOnce
        case .alertThirdButtonReturn:
            return .alwaysAllow
        default:
            return .denied
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
        case .blocked(let cmd):
            Log.info("MCP: blocked '\(cmd)' in \(context)")
            return jsonError("Command '\(cmd)' is blocked by MCP permissions.")
        case .needsApproval(let cmd):
            let result = onMain {
                self.requestCommandApproval(command: fullInput, flaggedCommand: cmd, permissions: permissions)
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
