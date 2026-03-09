import AppKit
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
    private var pendingApprovals: [String: (Bool) -> Void] = [:]
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
    private var allModels: [(windowID: Int, model: OverlayTabsModel)] {
        registeredModels.compactMap { entry in
            guard let model = entry.model else { return nil }
            return (entry.windowID, model)
        }
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

            let tabCountBefore = model.tabs.count
            if let dir = directory {
                model.newTab(at: dir)
            } else {
                model.newTab()
            }

            // Find the newly created tab — it's the one that didn't exist before
            // (newTab always selects the new tab, so selectedTabID is reliable here)
            guard model.tabs.count > tabCountBefore,
                  let tabIndex = model.tabs.firstIndex(where: { $0.id == model.selectedTabID }) else {
                return self.jsonError("Tab creation failed")
            }

            // Mark as MCP-controlled
            model.tabs[tabIndex].isMCPControlled = true
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
        if let err = enforceVerdict(MCPCommandFilter.check(command), fullInput: command, context: "tab \(tabID)") {
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
        if let err = enforceVerdict(MCPCommandFilter.checkRawInput(input), fullInput: input, context: "tab \(tabID)") {
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
            session.sendInput(input)
        }
        Log.info("MCP: send_input to \(tabID) (\(input.count) chars)")
        return encodeAny(["ok": true])
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

    func tabOutput(tabID: String, lines: Int) -> String {
        onMain {
            guard let (_, session) = self.resolveTab(tabID) else {
                return self.jsonError("Tab not found: \(tabID)")
            }

            let clampedLines = max(1, lines)

            guard let data = session.captureRemoteSnapshot() else {
                return self.encodeAny(["tab_id": tabID, "output": "", "lines": 0])
            }

            let text = String(decoding: data, as: UTF8.self)
            var outputLines = text.components(separatedBy: "\n")

            // Strip trailing empty lines (terminal buffer pads below cursor)
            while let last = outputLines.last,
                  last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                outputLines.removeLast()
            }

            if outputLines.count > clampedLines {
                outputLines = Array(outputLines.suffix(clampedLines))
            }

            var output = outputLines.joined(separator: "\n")

            // Cap total size — re-slice and update outputLines so count stays accurate
            if output.utf8.count > Self.maxOutputBytes {
                outputLines = Array(outputLines.suffix(max(1, clampedLines / 2)))
                output = outputLines.joined(separator: "\n")
            }

            return self.encodeAny([
                "tab_id": tabID,
                "output": output,
                "lines": outputLines.count
            ])
        }
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
        approvalLock.lock()
        let handler = pendingApprovals.removeValue(forKey: requestID)
        approvalLock.unlock()
        handler?(approved)
    }

    // MARK: - Helpers

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
            "status": session?.status.rawValue ?? "unknown",
            "cwd": session?.currentDirectory ?? "",
            "is_at_prompt": session?.isAtPrompt ?? false,
            "is_mcp_controlled": tab.isMCPControlled,
            "cto_active": tab.isTokenOptActive,
            "cto_override": tab.tokenOptOverride.rawValue
        ]
        if let app = session?.activeAppName {
            result["active_app"] = app
        }
        if let branch = session?.gitBranch {
            result["git_branch"] = branch
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

    /// Dual-path command approval: shows NSAlert on Mac AND sends request to iOS.
    /// First response (Mac or iOS) wins. Must be called on main thread.
    private func requestCommandApproval(command: String, flaggedCommand: String) -> Bool {
        let requestID = UUID().uuidString

        // Send approval request to iOS via RemoteControlManager
        let payload = ApprovalRequestPayload(
            requestID: requestID,
            command: command,
            flaggedCommand: flaggedCommand,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
        if let data = try? JSONEncoder().encode(payload) {
            onMainActor {
                RemoteControlManager.shared.sendApprovalRequest(requestID: requestID, payload: data)
            }
        }

        // Show local alert — this blocks the main thread until user clicks
        let alert = NSAlert()
        alert.messageText = "MCP Command Approval"
        alert.informativeText = "An MCP client wants to execute:\n\n\(command)\n\nAllow this command?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")

        // Register a handler so iOS response can dismiss the alert
        var iosResolved = false
        var iosApproved = false
        approvalLock.lock()
        pendingApprovals[requestID] = { approved in
            iosResolved = true
            iosApproved = approved
            // Dismiss the Mac alert from iOS response
            DispatchQueue.main.async {
                NSApp.stopModal(withCode: approved ? .alertFirstButtonReturn : .alertSecondButtonReturn)
            }
        }
        approvalLock.unlock()

        let response = alert.runModal()

        // Clean up pending handler if Mac user responded first
        approvalLock.lock()
        pendingApprovals.removeValue(forKey: requestID)
        approvalLock.unlock()

        if iosResolved {
            return iosApproved
        }
        return response == .alertFirstButtonReturn
    }

    /// Returns an error string if the verdict blocks/denies execution, nil if allowed.
    private func enforceVerdict(_ verdict: MCPCommandVerdict, fullInput: String, context: String) -> String? {
        switch verdict {
        case .allowed:
            return nil
        case .blocked(let cmd):
            Log.info("MCP: blocked '\(cmd)' in \(context)")
            return jsonError("Command '\(cmd)' is blocked by MCP permissions.")
        case .needsApproval(let cmd):
            let approved = onMain { self.requestCommandApproval(command: fullInput, flaggedCommand: cmd) }
            if !approved {
                Log.info("MCP: user denied '\(cmd)' in \(context)")
                return jsonError("Command '\(cmd)' was denied by user.")
            }
            return nil
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

// MARK: - Approval Payloads

struct ApprovalRequestPayload: Codable {
    let requestID: String
    let command: String
    let flaggedCommand: String
    let timestamp: String

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case command
        case flaggedCommand = "flagged_command"
        case timestamp
    }
}

struct ApprovalResponsePayload: Codable {
    let requestID: String
    let approved: Bool

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case approved
    }
}
