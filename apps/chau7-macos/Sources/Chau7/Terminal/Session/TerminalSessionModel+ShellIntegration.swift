import Foundation
import AppKit
import Chau7Core

// MARK: - Shell Integration (OSC 133 sequences, command detection, AI tool detection)

// Extracted from TerminalSessionModel.swift
// Contains: OSC 133 handling, command detection, AI tool detection,
// git status refresh, dev server monitoring, process lifecycle.

extension TerminalSessionModel {
    /// Schedules shell integration script to run after shell is ready.
    /// Instead of an arbitrary delay, we wait for initial output (prompt).
    func scheduleShellIntegration(for view: any TerminalViewLike) {
        // The shell integration will be applied when we detect the first few outputs,
        // indicating the shell has started and is ready for input.
        didApplyShellIntegration = false
        shellIntegrationOutputCount = 0
    }

    func maybeApplyShellIntegration() {
        guard !didApplyShellIntegration else { return }
        guard let view = activeTerminalView else { return }

        // Wait for a few output events to ensure shell is ready
        shellIntegrationOutputCount += 1
        if shellIntegrationOutputCount >= 2 {
            didApplyShellIntegration = true
            applyShellIntegration(to: view)
        }
    }

    func handleInput(_ text: String) {
        lastInputAt = Date()
        let sanitizedText = sanitizeInputForBuffer(text)
        guard !sanitizedText.isEmpty else { return }
        let echoDisabled = activeTerminalView?.isPtyEchoDisabled ?? false

        if !sanitizedText.isEmpty {
            markInputLatencyStart()
        }
        inputBuffer.append(sanitizedText)
        if SensitiveInputGuard.shouldPersistInput(sanitizedText, echoDisabled: echoDisabled) {
            aiLogQueue.async { [weak self] in
                self?.aiLogSession?.recordInput(sanitizedText)
            }
        }
        if sanitizedText.contains("\n") || sanitizedText.contains("\r") {
            processInputBuffer()
            markRunning()
        }
    }

    func dangerousCommandCheckForDirectUserInput(_ text: String) -> DangerousCommandGuard.CheckResult? {
        let sanitizedText = sanitizeInputForBuffer(text)
        guard !sanitizedText.isEmpty else { return nil }
        guard sanitizedText.contains("\n") || sanitizedText.contains("\r") else { return nil }

        let pendingCommand = inputBuffer + sanitizedText
        let shellPID = existingRustTerminalView?.shellPid ?? 0
        let extraProtectedPIDs: Set<Int32> = shellPID > 0 ? [shellPID] : []
        let observedProcesses = processGroup?.children.map(\.name) ?? []
        let selfProtectionContext = FeatureSettings.shared.dangerousCommandSelfProtectionContext(
            extraProtectedPIDs: extraProtectedPIDs,
            observedProcessNames: observedProcesses
        )

        return MainActor.assumeIsolated {
            DangerousCommandGuard.shared.check(
                commandLine: pendingCommand,
                directory: currentDirectory,
                selfProtectionContext: selfProtectionContext
            )
        }
    }

    func shouldAcceptDirectUserInput(_ text: String) -> Bool {
        guard let result = dangerousCommandCheckForDirectUserInput(text) else { return true }

        switch result {
        case .safe, .allowed:
            return true
        case .needsConfirmation(let command, let matchedPattern, let reason):
            return MainActor.assumeIsolated {
                DangerousCommandGuard.shared.showConfirmation(
                    command: command,
                    matchedPattern: matchedPattern,
                    reason: reason
                )
            }
        case .blocked(let reason):
            let sanitizedText = sanitizeInputForBuffer(text)
            let pendingCommand = (inputBuffer + sanitizedText).trimmingCharacters(in: .whitespacesAndNewlines)
            MainActor.assumeIsolated {
                DangerousCommandGuard.shared.showBlockedAlert(command: pendingCommand, reason: reason)
            }
            return false
        }
    }

    func handleOutput(_ data: Data) {
        if shellStartupSlow { shellStartupSlow = false }

        // Fix #6: Split output processing - light work inline, heavy work on background queue
        let outputToken = FeatureProfiler.shared.begin(.outputProcessing, bytes: data.count)
        let now = Date()
        let outputGap = now.timeIntervalSince(lastOutputAt)
        lastOutputAt = now

        // Light operations that need immediate execution (timing-sensitive)
        if !data.isEmpty {
            updateOutputBurstState(bytes: data.count, outputGap: outputGap, now: now)
            markOutputLatencyStart()
            markDirtyOutputRange(for: data)
            noteAIFirstOutputIfNeeded(bytes: data.count, at: now)
            markWaitingInputFallbackOutputIfNeeded()
        }
        bufferNeedsRefresh = true
        recordInputLatencyIfNeeded()

        // Remote output enqueueing (already uses its own queue internally)
        enqueueRemoteOutput(data)

        // Capture source for background processing
        let source = activeAppName ?? title

        // Heavy processing on background queue to avoid blocking UI
        outputProcessingQueue.async { [weak self] in
            guard let self = self else { return }

            // Terminal output capture (thread-safe singleton)
            TerminalOutputCapture.shared.record(data: data, source: source)

            // Convert to text once for reuse
            let outputText = String(data: data, encoding: .utf8)

            // Shell event detection
            if let outputText {
                shellEventDetector.processOutput(outputText)
            }

            // Semantic detection (expensive)
            if FeatureSettings.shared.isSemanticSearchEnabled,
               data.contains(where: { $0 == 0x0A || $0 == 0x0D }) {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if let row = currentBufferRow() {
                        let token = FeatureProfiler.shared.begin(.semantic)
                        semanticDetector.updateCurrentRow(row)
                        FeatureProfiler.shared.end(token)
                    }
                }
            }

            // AI log processing: parse metadata under aiLogQueue.sync (fast, in-memory,
            // but must be serialized with startAILogging/finishAILogging which access
            // the same aiLogSession and aiLogPrefixBuffer state).
            // Disk write (recordOutput) is deferred to async to avoid blocking output.
            var aiExitCode: Int?
            var logData: Data?
            aiLogQueue.sync {
                let aiLogResult = self.processAILogOutput(data)
                aiExitCode = aiLogResult.exitCode
                logData = aiLogResult.loggable
            }
            if let logData, !logData.isEmpty {
                aiLogQueue.async { [weak self] in
                    self?.aiLogSession?.recordOutput(logData)
                }
            }

            // UI-related updates need main thread
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let mainToken = FeatureProfiler.shared.begin(.outputMainThread, bytes: data.count)
                FeatureProfiler.shared.end(outputToken)

                if let exitCode = aiExitCode {
                    finishAILogging(exitCode: exitCode)
                }

                // Shell integration check
                maybeApplyShellIntegration()

                // Prompt update handling
                let promptToken = FeatureProfiler.shared.begin(.promptUpdate, bytes: data.count)
                let sawPromptUpdate = maybeHandlePromptUpdate(data)
                FeatureProfiler.shared.end(promptToken)

                // AI app detection — skip while a command is pending detection
                // (handleInputLine hasn't run yet), so command-based detection
                // gets priority over output pattern matching.
                if !sawPromptUpdate, !commandPendingDetection {
                    maybeDetectAppFromOutput(data)
                }

                // Dangerous output recording
                if outputText != nil {
                    recordDangerousOutputIfNeeded()
                }

                // AI waiting detection
                maybeDetectAIWaitingForInput(data)

                // Dev server detection
                let devToken = FeatureProfiler.shared.begin(.devServerDetect, bytes: data.count)
                maybeDetectDevServer(data)
                FeatureProfiler.shared.end(devToken)

                FeatureProfiler.shared.end(mainToken)
            }
        }
    }

    private func maybeDetectDevServer(_ data: Data) {
        // Start the dev server monitor if not already started
        if !didStartDevServerMonitor {
            var pid: pid_t = 0

            if let rustView = rustTerminalView {
                pid = rustView.shellPid
                Log.trace("TerminalSessionModel: Got shell PID from Rust backend: \(pid)")
            }

            if pid > 0 {
                didStartDevServerMonitor = true
                devServerMonitor.start(shellPID: pid)
                Log.info("TerminalSessionModel: Started dev server monitor with PID \(pid)")
            }
        }

        // Check output for dev server patterns
        guard devServer == nil else { return } // Already detected
        let checkData = data.prefix(2048)
        guard let output = String(data: checkData, encoding: .utf8) else { return }
        devServerMonitor.checkOutput(output)
    }

    /// Detects when an AI agent is waiting for user input (prompts, permission requests, etc.)
    private func maybeDetectAIWaitingForInput(_ data: Data) {
        guard activeAppName != nil else { return }
        guard let text = String(data: data, encoding: .utf8) else { return }

        let token = FeatureProfiler.shared.begin(.aiDetect, bytes: data.count, metadata: "wait-for-input")
        defer { FeatureProfiler.shared.end(token) }

        let approvalPatterns = [
            "needs your approval",
            "needs your permission",
            "approval required",
            "approve this command",
            "allow once",
            "always allow"
        ]
        let waitingPatterns = [
            "Yes/No",
            "[y/N]",
            "[Y/n]",
            "(y/n)",
            "Allow?",
            "Approve?",
            "Continue?",
            "Proceed?",
            "Permission",
            "> ", // Common prompt indicator
            "? ", // Question prompt
            "Enter your",
            "Type your",
            "waiting for"
        ]

        let lowercased = text.lowercased()
        let loweredApprovalPatterns = approvalPatterns.map { $0.lowercased() }
        let loweredWaitingPatterns = waitingPatterns.map { $0.lowercased() }
        let isApprovalRequired: Bool
        if let rustMatch = RustPatternMatcher.waitPatterns.containsAny(haystack: lowercased, patterns: loweredApprovalPatterns) {
            isApprovalRequired = rustMatch
        } else {
            isApprovalRequired = approvalPatterns.contains { pattern in
                lowercased.contains(pattern.lowercased())
            }
        }
        let isWaiting: Bool
        if let rustMatch = RustPatternMatcher.waitPatterns.containsAny(haystack: lowercased, patterns: loweredWaitingPatterns) {
            isWaiting = rustMatch
        } else {
            isWaiting = waitingPatterns.contains { pattern in
                lowercased.contains(pattern.lowercased())
            }
        }

        if isApprovalRequired || isWaiting {
            DispatchQueue.main.async { [weak self] in
                guard let self, status == .running || status == .stuck else { return }
                status = isApprovalRequired ? .approvalRequired : .waitingForInput
                Log.trace("AI agent blocked detected status=\(status.rawValue)")
            }
        }
    }

    func processAILogOutput(_ data: Data) -> (loggable: Data?, exitCode: Int?) {
        guard aiLogSession != nil || !aiLogPrefixBuffer.isEmpty else { return (nil, nil) }
        var combined = aiLogPrefixBuffer
        combined.append(data)
        aiLogPrefixBuffer.removeAll(keepingCapacity: true)

        if let prefixRange = combined.range(of: Self.aiExitMarkerPrefix) {
            let loggable = Data(combined[..<prefixRange.lowerBound])
            let afterPrefix = prefixRange.upperBound
            if let suffixRange = combined.range(of: Self.aiExitMarkerSuffix, in: afterPrefix ..< combined.endIndex) {
                let payload = combined[afterPrefix ..< suffixRange.lowerBound]
                let exitCode = parseAIExitCode(payload)
                aiLogPrefixBuffer.removeAll(keepingCapacity: true)
                return (loggable, exitCode)
            }
            aiLogPrefixBuffer = Data(combined[prefixRange.lowerBound...])
            return (loggable, nil)
        }

        let keep = Self.aiExitMarkerKeepBytes
        if combined.count > keep {
            let cutIndex = combined.count - keep
            let loggable = Data(combined[..<cutIndex])
            aiLogPrefixBuffer = Data(combined[cutIndex...])
            return (loggable, nil)
        }

        aiLogPrefixBuffer = combined
        return (nil, nil)
    }

    private func parseAIExitCode(_ payload: Data) -> Int? {
        let raw = String(decoding: payload, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = Int(raw) {
            return value
        }
        if let range = raw.range(of: "exit=") {
            let digits = raw[range.upperBound...].prefix { $0.isNumber }
            return Int(digits)
        }
        return nil
    }

    func startAILoggingIfNeeded(toolName: String, commandLine: String?) {
        // Synchronized access to AI log state
        aiLogQueue.sync {
            guard aiLogSession == nil else { return }
            let logPath = terminalLogPath(for: toolName)
            aiLogSession = AITerminalLogSession(toolName: toolName, logPath: logPath)
            lastPTYLogPath = logPath
            let trimmedCommand = commandLine.flatMap { SensitiveInputGuard.sanitizedCommandForPersistence($0) }
            aiLogContext = AILogContext(toolName: toolName, commandLine: trimmedCommand, logPath: logPath)
            aiLogPrefixBuffer.removeAll(keepingCapacity: true)
            noteAgentLaunch(toolName: toolName, commandLine: trimmedCommand)

            let message: String
            if let trimmedCommand, !trimmedCommand.isEmpty {
                message = "Started: \(trimmedCommand)"
            } else {
                message = "Started (detected from output)"
            }
            AIEventLogWriter.appendEvent(
                type: "info",
                tool: toolName,
                message: message,
                source: .terminalSession,
                logPath: eventsLogPath()
            )
        }
    }

    func finishAILogging(exitCode: Int?) {
        // Capture terminal buffer snapshot for telemetry fallback transcript.
        // Prefer a fresh capture (runs on main where the view is accessible),
        // but fall back to the cached buffer if the view was already detached.
        let bufferSnapshot = captureRemoteSnapshot() ?? cachedBufferData

        // Grab the PTY log path and flush pending writes before reading.
        // For TUI-based AI tools (alternate screen), the terminal buffer will be
        // nearly empty — the PTY log is the only source of the agent's output.
        let ptyLogPath: String? = aiLogQueue.sync {
            aiLogSession?.close() // drain write queue so readPTYLogTail sees all data
            return aiLogContext?.logPath
        }
        // Preserve for MCP tools that need the PTY log after the session ends
        lastPTYLogPath = ptyLogPath

        // Telemetry: record run end (with fallback sources)
        TelemetryRecorder.shared.runEnded(
            tabID: tabIdentifier,
            exitStatus: exitCode,
            terminalBuffer: bufferSnapshot,
            ptyLogPath: ptyLogPath
        )

        // Notify shell event detector (outside lock to avoid potential deadlock)
        commandFinishedNotified = true
        promptSeenForPendingCommand = true

        // Synchronized access to AI log state
        aiLogQueue.sync {
            shellEventDetector.commandFinished(exitCode: exitCode, command: aiLogContext?.commandLine)

            guard let context = aiLogContext else {
                // If aiLogSession still exists, a prior caller already cleared aiLogContext
                // but we never logged a "Finished" event — emit one now to avoid orphaned starts
                if let session = aiLogSession {
                    AIEventLogWriter.appendEvent(
                        type: "finished",
                        tool: session.toolName,
                        message: "Finished (cleanup)",
                        source: .terminalSession,
                        logPath: eventsLogPath()
                    )
                }
                aiLogSession?.close()
                aiLogSession = nil
                aiLogPrefixBuffer.removeAll(keepingCapacity: true)
                return
            }

            let type: String
            if let exitCode, exitCode != 0 {
                type = "failed"
            } else {
                type = "finished"
            }

            let message: String
            if let command = context.commandLine, !command.isEmpty {
                if let exitCode {
                    message = "\(type.capitalized) (exit \(exitCode)): \(command)"
                } else {
                    message = "\(type.capitalized): \(command)"
                }
            } else if let exitCode {
                message = "\(type.capitalized) (exit \(exitCode))"
            } else {
                message = "\(type.capitalized)"
            }

            AIEventLogWriter.appendEvent(
                type: type,
                tool: context.toolName,
                message: message,
                source: .terminalSession,
                logPath: eventsLogPath()
            )

            aiLogSession?.close()
            aiLogSession = nil
            aiLogContext = nil
            aiLogPrefixBuffer.removeAll(keepingCapacity: true)
        }
    }

    private func eventsLogPath() -> String {
        let trimmed = appModel?.logPath.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return trimmed
        }
        return RuntimeIsolation.pathInHome(".ai-events.log")
    }

    private func terminalLogPath(for toolName: String) -> String {
        let trimmed = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let appModel, let path = appModel.terminalLogPath(forToolName: trimmed), !path.isEmpty {
            return path
        }
        let logDir = RuntimeIsolation.logsDirectory()
            .appendingPathComponent("Chau7", isDirectory: true).path
        let slug = sanitizeToolName(trimmed)
        return "\(logDir)/\(slug)-pty.log"
    }

    private func sanitizeToolName(_ toolName: String) -> String {
        let lowercased = toolName.lowercased()
        var slug = ""
        slug.reserveCapacity(lowercased.count)
        for scalar in lowercased.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                slug.append(Character(scalar))
            } else if scalar.value == 0x20 || scalar.value == 0x2D || scalar.value == 0x5F {
                if !slug.hasSuffix("-") {
                    slug.append("-")
                }
            }
        }
        if slug.hasSuffix("-") {
            slug.removeLast()
        }
        return slug.isEmpty ? "ai-cli" : slug
    }

    private func maybeHandlePromptUpdate(_ data: Data) -> Bool {
        guard data.range(of: Self.osc7Prefix) != nil else { return false }
        if Thread.isMainThread {
            clearActiveAppAfterPrompt()
            handlePromptDetected()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.clearActiveAppAfterPrompt()
                self?.handlePromptDetected()
            }
        }
        return true
    }

    func notifyCommandBlockStarted() {
        let tabID = ownerTabID?.uuidString
        let cmd = pendingCommandLine ?? ""
        let dir = currentDirectory
        DispatchQueue.main.async {
            guard let tabID else { return }
            CommandBlockManager.shared.commandStarted(tabID: tabID, command: cmd, line: 0, directory: dir)
        }
    }

    func notifyCommandBlockFinished(exitCode: Int) {
        let tabID = ownerTabID?.uuidString
        DispatchQueue.main.async {
            guard let tabID else { return }
            CommandBlockManager.shared.commandFinished(tabID: tabID, line: 0, exitCode: exitCode)
        }
    }

    func clearActiveAppAfterPrompt() {
        guard aiDetection.handlePromptReturn() else { return }
        Log.trace("Clearing active app after OSC 7 prompt update.")
        activeAppName = aiDetection.currentApp // nil after prompt return
        // finishAILogging is idempotent and has internal synchronization
        finishAILogging(exitCode: nil)
    }

    func handlePromptDetected() {
        let previousStatus = status
        if isShellLoading { isShellLoading = false }
        isAtPrompt = true
        // Transition status to idle when the prompt returns — the command cycle
        // is complete. Without this, status stays .running forever when OSC 133
        // clears hasPendingCommand (blocking the idle timer from transitioning).
        if status == .running || status == .stuck || status == .waitingForInput || status == .approvalRequired {
            if activeAppName != nil || effectiveAIProvider != nil || lastDetectedAppName != nil {
                status = .done
            } else {
                status = .idle
            }
        }
        createDeferredCTOFlag()
        devServerMonitor.commandDidFinish()
        flushPendingPrefillInputIfReady()
        emitWaitingInputFallbackIfNeeded(previousStatus: previousStatus)
        clearWaitingInputFallbackTracking()
        guard hasPendingCommand, pendingCommandLine != nil else { return }
        promptSeenForPendingCommand = true
        if !commandFinishedNotified {
            commandFinishedNotified = true
            shellEventDetector.commandFinished(exitCode: nil, command: pendingCommandLine)
        }
    }

    private func emitWaitingInputFallbackIfNeeded(previousStatus: CommandStatus) {
        let runtimeOwnsTab = ownerTabID.flatMap { RuntimeSessionManager.shared.sessionForTab($0) } != nil
        let resumeCommand = pendingCommandLine.flatMap(AIResumeParser.extractMetadata(from:))
        if aiDetection.isRestored && suppressWaitingInputFallbackUntilNextUserCommand {
            if !didLogRestoreSuppressionOnce {
                didLogRestoreSuppressionOnce = true
                Log.info(
                    "Suppressing waiting_input fallback for restored tab=\(tabIdentifier) provider=\(effectiveAIProvider ?? "nil") until user command"
                )
            }
            return
        }
        let context = TerminalPromptNotificationContext(
            previousStatus: previousStatus.rawValue,
            hasOwnerTab: ownerTabID != nil,
            runtimeOwnsTab: runtimeOwnsTab,
            providerID: effectiveAIProvider,
            providerIsRestored: aiDetection.isRestored,
            hasPendingPrefillInput: hasPendingResumePrefillActivity,
            suppressUntilNextUserCommand: suppressWaitingInputFallbackUntilNextUserCommand,
            hasRecentSystemResumePrefill: deliveredSystemResumePrefillSinceLastUserCommand,
            commandLooksLikeResume: resumeCommand != nil,
            observedAIRoundTrip: pendingWaitingInputFallbackArmed && pendingWaitingInputFallbackSawLiveOutput,
            sessionID: effectiveAISessionId,
            providerHasAuthoritativeNotifications: hasAuthoritativeNotifications(for: effectiveAIProvider)
        )
        guard TerminalPromptNotificationAdapter.shouldEmitWaitingInput(from: context),
              let provider = effectiveAIProvider,
              let source = AIEventSource.forProvider(provider),
              let ownerTabID else {
            return
        }

        let toolName = aiDisplayAppName
            ?? Self.displayName(fromProvider: provider)
            ?? notificationTabName
        let projectName = URL(fileURLWithPath: currentDirectory).lastPathComponent
        let location = projectName.isEmpty ? notificationTabName : projectName

        appModel?.recordEvent(
            source: source,
            type: "waiting_input",
            tool: toolName,
            message: "\(toolName) is waiting for your input in \(location)",
            notify: true,
            directory: currentDirectory,
            tabID: ownerTabID,
            sessionID: effectiveAISessionId,
            producer: "terminal_prompt_waiting_input",
            reliability: .fallback
        )
    }

    private func hasAuthoritativeNotifications(for provider: String?) -> Bool {
        guard let normalizedProvider = AIResumeParser.normalizeProviderName(provider ?? "") else {
            return false
        }

        switch normalizedProvider {
        case "claude":
            return true
        case "codex":
            let helperPath = RuntimeIsolation.pathInHome(".chau7/bin/\(CodexNotifyHookConfiguration.helperName)")
            let configPath = RuntimeIsolation.pathInHome(".codex/config.toml")
            guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else {
                return false
            }
            return CodexNotifyHookConfiguration.notifyIncludesHelper(in: content, helperPath: helperPath)
        default:
            return false
        }
    }

    private func markWaitingInputFallbackOutputIfNeeded() {
        guard pendingWaitingInputFallbackArmed else { return }
        guard activeAppName != nil || lastDetectedAppName != nil else { return }
        pendingWaitingInputFallbackSawLiveOutput = true
    }

    private func markInputLatencyStart() {
        let timestamp = CFAbsoluteTimeGetCurrent()
        if Thread.isMainThread {
            pendingInputLatencyAt = timestamp
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.pendingInputLatencyAt = timestamp
            }
        }
    }

    private func clearPendingInputLatencyMeasurement() {
        if Thread.isMainThread {
            pendingInputLatencyAt = nil
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.pendingInputLatencyAt = nil
            }
        }
    }

    private func recordInputLatencyIfNeeded() {
        guard pendingInputLatencyAt != nil else { return }
        let now = CFAbsoluteTimeGetCurrent()
        if Thread.isMainThread {
            recordInputLatencyIfNeeded(now: now)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.recordInputLatencyIfNeeded(now: now)
            }
        }
    }

    private func recordInputLatencyIfNeeded(now: CFAbsoluteTime) {
        guard let start = pendingInputLatencyAt else { return }
        pendingInputLatencyAt = nil
        let elapsedMs = max(0, (now - start) * 1000)
        guard elapsedMs <= maxAcceptedLatencyMs else {
            Log.debug("Discarded stale input latency sample: \(Int(elapsedMs.rounded()))ms")
            return
        }
        inputLatencySamples.append(Int(elapsedMs.rounded()))
        inputLatencySampleCount += 1
        inputLatencyTotalMs += elapsedMs
        inputLatencyMs = Int(elapsedMs.rounded())
        inputLatencyAverageMs = inputLatencySamples.recentAverage()
        maybeLogLatencySpike(
            kind: "input",
            elapsedMs: elapsedMs,
            averageMs: inputLatencyAverageMs,
            samples: inputLatencySamples,
            thresholdMs: inputLagLogThresholdMs,
            lastLoggedAt: &lastInputLagLogAt
        )
    }

    private func markOutputLatencyStart() {
        let timestamp = CFAbsoluteTimeGetCurrent()
        if Thread.isMainThread {
            if pendingOutputLatencyAt == nil {
                pendingOutputLatencyAt = timestamp
                scheduleOutputLatencyFallback()
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if pendingOutputLatencyAt == nil {
                    pendingOutputLatencyAt = timestamp
                    scheduleOutputLatencyFallback()
                }
            }
        }
    }

    func recordOutputLatencyIfNeeded() {
        guard pendingOutputLatencyAt != nil else { return }
        let now = CFAbsoluteTimeGetCurrent()
        if Thread.isMainThread {
            recordOutputLatencyIfNeeded(now: now)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.recordOutputLatencyIfNeeded(now: now)
            }
        }
    }

    private func recordOutputLatencyIfNeeded(now: CFAbsoluteTime) {
        guard let start = pendingOutputLatencyAt else { return }
        pendingOutputLatencyAt = nil
        outputLatencyFallbackWorkItem?.cancel()
        outputLatencyFallbackWorkItem = nil
        let elapsedMs = max(0, (now - start) * 1000)
        guard elapsedMs <= maxAcceptedLatencyMs else {
            Log.debug("Discarded stale output latency sample: \(Int(elapsedMs.rounded()))ms")
            return
        }
        outputLatencySamples.append(Int(elapsedMs.rounded()))
        outputLatencySampleCount += 1
        outputLatencyTotalMs += elapsedMs
        outputLatencyMs = Int(elapsedMs.rounded())
        outputLatencyAverageMs = outputLatencySamples.recentAverage()
        maybeLogLatencySpike(
            kind: "output",
            elapsedMs: elapsedMs,
            averageMs: outputLatencyAverageMs,
            samples: outputLatencySamples,
            thresholdMs: outputLagLogThresholdMs,
            lastLoggedAt: &lastOutputLagLogAt
        )
    }

    private func scheduleOutputLatencyFallback() {
        guard outputLatencyFallbackWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.clearPendingOutputLatencyMeasurement()
        }
        outputLatencyFallbackWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + outputLatencyFallbackSeconds, execute: work)
    }

    private func clearPendingOutputLatencyMeasurement() {
        guard pendingOutputLatencyAt != nil else { return }
        pendingOutputLatencyAt = nil
        outputLatencyFallbackWorkItem?.cancel()
        outputLatencyFallbackWorkItem = nil
        Log.trace("Cleared synthetic output latency sample after fallback timeout")
    }

    private func markDirtyOutputRange(for data: Data) {
        guard let endRow = currentBufferRow() else { return }
        var newlineCount = 0
        for byte in data where byte == 0x0A {
            newlineCount += 1
        }
        let startRow = max(0, endRow - max(1, newlineCount + 1))
        let newRange = startRow ... endRow
        if let existing = dirtyOutputRange {
            dirtyOutputRange = min(existing.lowerBound, newRange.lowerBound) ... max(existing.upperBound, newRange.upperBound)
        } else {
            dirtyOutputRange = newRange
        }
    }

    private func updateOutputBurstState(bytes: Int, outputGap: TimeInterval, now: Date) {
        if outputGap > outputBurstIdleThreshold {
            outputBurstStartAt = now
            outputBurstBytes = 0
            outputBurstChunks = 0
            outputBurstActive = false
        }

        outputBurstBytes += bytes
        outputBurstChunks += 1

        let window = now.timeIntervalSince(outputBurstStartAt)
        if !outputBurstActive {
            if window > outputBurstWindowSeconds {
                outputBurstStartAt = now
                outputBurstBytes = bytes
                outputBurstChunks = 1
            }
            let inWindow = now.timeIntervalSince(outputBurstStartAt) <= outputBurstWindowSeconds
            if inWindow,
               outputBurstBytes >= outputBurstBytesThreshold || outputBurstChunks >= outputBurstChunksThreshold {
                outputBurstActive = true
            }
        }
    }

    private func enqueueRemoteOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        if !remoteOutputBatchingEnabled {
            let sessionID = tabIdentifier
            Task { @MainActor in
                RemoteControlManager.shared.recordOutput(data, sessionIdentifier: sessionID)
            }
            return
        }
        remoteOutputQueue.async { [weak self] in
            guard let self else { return }
            pendingRemoteOutput.append(data)

            if pendingRemoteOutput.count >= remoteOutputMaxBufferBytes {
                remoteOutputFlushWorkItem?.cancel()
                remoteOutputFlushWorkItem = nil
                flushRemoteOutput()
                return
            }

            if remoteOutputFlushWorkItem == nil {
                let work = DispatchWorkItem { [weak self] in
                    self?.flushRemoteOutput()
                }
                remoteOutputFlushWorkItem = work
                remoteOutputQueue.asyncAfter(deadline: .now() + remoteOutputFlushInterval, execute: work)
            }
        }
    }

    private func flushRemoteOutput() {
        let payload = pendingRemoteOutput
        pendingRemoteOutput.removeAll(keepingCapacity: true)
        remoteOutputFlushWorkItem = nil
        guard !payload.isEmpty else { return }
        let sessionID = tabIdentifier
        Task { @MainActor in
            RemoteControlManager.shared.recordOutput(payload, sessionIdentifier: sessionID)
        }
    }

    /// Attempts to detect AI CLI from output patterns when command detection missed it.
    ///
    /// Improvements over the original implementation:
    /// Detects AI tool from terminal output using the `AIDetectionState` state machine.
    ///
    /// The state machine handles: sliding buffer, phase gating, cooldown,
    /// re-detection locking (same tool only), and retry window exhaustion.
    /// This method only does pattern matching and fires side effects on state change.
    private func maybeDetectAppFromOutput(_ data: Data) {
        // State machine handles phase checks, sliding buffer, and retry window.
        // Returns nil when scanning should be skipped (already detected, window exhausted, etc.)
        let failuresBefore = aiDetection.utf8DecodeFailures
        guard let haystack = aiDetection.prepareHaystack(chunk: data) else {
            if aiDetection.utf8DecodeFailures > failuresBefore {
                if aiDetection.utf8DecodeFailures == 1 {
                    Log.warn("First UTF-8 decode failure in AI detection sliding buffer — may indicate encoding issue")
                } else {
                    Log.trace("UTF-8 decode failure in AI detection sliding buffer (total: \(aiDetection.utf8DecodeFailures))")
                }
            }
            return
        }

        let token = FeatureProfiler.shared.begin(.aiDetect, bytes: data.count, metadata: "output-patterns")
        defer { FeatureProfiler.shared.end(token) }

        let patterns = outputDetectionPatterns()
        let patternStrings = patterns.map { $0.pattern }

        // Find a match — state machine will decide whether to accept it
        var matchedApp: String?
        var matchedPattern: String?

        // Fast path: Rust Aho-Corasick on the lowercased haystack
        if let index = RustPatternMatcher.outputPatterns.firstMatchIndex(haystack: haystack, patterns: patternStrings) {
            if index >= 0, index < patterns.count {
                matchedApp = patterns[index].appName
                matchedPattern = patterns[index].pattern
            }
        }

        // Fallback: linear scan (patterns already lowercased, haystack already lowercased)
        if matchedApp == nil {
            for (pattern, appName) in patterns {
                if haystack.contains(pattern) {
                    matchedApp = appName
                    matchedPattern = pattern
                    break
                }
            }
        }

        let authoritativeAppName =
            activeAppName
                ?? lastDetectedAppName
                ?? Self.displayName(fromProvider: lastAIProvider)
        let allowRestoredProviderOverride = shouldAllowRestoredProviderOverride(
            matchedAppName: matchedApp,
            authoritativeAppName: authoritativeAppName
        )

        // State machine filters: redetecting rejects different tools, and
        // output-only detection is not allowed to flip an established provider.
        guard aiDetection.handleOutputMatch(
            appName: matchedApp,
            authoritativeAppName: authoritativeAppName,
            allowRestoredProviderOverride: allowRestoredProviderOverride
        ),
            let app = aiDetection.currentApp else { return }

        // State changed → sync @Published property and fire side effects
        activeAppName = app
        updateLastDetectedApp(app)
        startAILoggingIfNeeded(toolName: app, commandLine: nil)

        let runtimeSession = ownerTabID.flatMap { RuntimeSessionManager.shared.sessionForTab($0) }
        var taskMetadata = runtimeSession?.config.taskMetadata ?? [:]
        if let runtimeSession {
            taskMetadata["runtime_session_id"] = runtimeSession.id
            taskMetadata["runtime_backend"] = runtimeSession.backend.name
            taskMetadata["delegation_depth"] = "\(runtimeSession.config.delegationDepth)"
            if let purpose = runtimeSession.config.purpose {
                taskMetadata["runtime_purpose"] = purpose
            }
            if let parentSessionID = runtimeSession.config.parentSessionID {
                taskMetadata["parent_session_id"] = parentSessionID
            }
        }

        TelemetryRecorder.shared.runStarted(
            tabID: tabIdentifier,
            provider: AIResumeParser.normalizeProviderName(app) ?? app,
            cwd: currentDirectory,
            repoPath: gitRootPath,
            sessionID: lastAISessionId,
            parentRunID: runtimeSession?.config.parentRunID,
            metadata: taskMetadata
        )

        Log.info("AI detected from output pattern: \(app) (matched: \(matchedPattern ?? "unknown"))")
    }

    private func outputDetectionPatterns() -> [(pattern: String, appName: String)] {
        let custom = FeatureSettings.shared.customAIDetectionRules.compactMap { rule -> (String, String)? in
            let trimmedPattern = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedName = rule.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPattern.isEmpty else { return nil }
            let name = trimmedName.isEmpty ? "Custom AI" : trimmedName
            return (trimmedPattern, name)
        }
        return CommandDetection.outputDetectionPatterns + custom
    }

    private func markRunning() {
        // When OSC 133 is active, the shell's command lifecycle signals (B/C/D)
        // handle status transitions authoritatively. Don't re-arm .running from
        // input echoes — it would override the .idle set by handlePromptDetected().
        guard !hasShellIntegration else { return }
        if status != .running, status != .stuck {
            status = .running
            commandStartedAt = Date()
        }
        // Note: hasPendingCommand is set by OSC 133 B (commandStart) or
        // handleInputLine() — NOT here. Setting it on every newline caused
        // the fallback completion timer to re-arm after idle, producing
        // repeated false "finished" notifications.
    }

    private func sanitizeInputForBuffer(_ text: String) -> String {
        guard text.contains("\u{1b}") else { return text }
        guard let data = text.data(using: .utf8) else { return text }

        var output = Data()
        var index = 0
        while index < data.count {
            let byte = data[index]
            if byte != 0x1B {
                output.append(byte)
                index += 1
                continue
            }

            index += 1
            guard index < data.count else { break }

            let next = data[index]
            if next == 0x5B {
                // CSI sequence: ESC [ ... final byte [@-~]
                index += 1
                while index < data.count {
                    let current = data[index]
                    if current >= 0x40, current <= 0x7E {
                        index += 1
                        break
                    }
                    index += 1
                }
                continue
            }

            if next == 0x5D || next == 0x50 {
                // OSC / DCS sequence (terminated by BEL or ESC \)
                index += 1
                while index < data.count {
                    if data[index] == 0x07 {
                        index += 1
                        break
                    }
                    if data[index] == 0x1B,
                       index + 1 < data.count,
                       data[index + 1] == 0x5C {
                        index += 2
                        break
                    }
                    index += 1
                }
                continue
            }

            // Generic escape + one byte (legacy function keys / modifier codes)
            index += 1
        }

        return String(data: output, encoding: .utf8) ?? text
    }

    private func processInputBuffer() {
        let normalized = inputBuffer.replacingOccurrences(of: "\r", with: "\n")
        let parts = normalized.components(separatedBy: "\n")
        if parts.count <= 1 {
            return
        }
        for line in parts.dropLast() {
            handleInputLine(line)
        }
        inputBuffer = parts.last ?? ""
    }

    private func applyCTOPrefixIfNeeded(to line: String) -> String {
        guard FeatureSettings.shared.isCTOEnabled(forTabIdentifier: tabIdentifier) else { return line }
        let prefix = FeatureSettings.shared.ctoPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { return line }
        guard !line.isEmpty else { return line }
        if line.hasPrefix(prefix) { return line }
        let needsSeparator = !prefix.hasSuffix(" ") && !line.hasPrefix(" ")
        return needsSeparator ? "\(prefix) \(line)" : "\(prefix)\(line)"
    }

    func handleInputLine(_ line: String) {
        // Sanitize input to remove escape sequences that contaminate history/logs
        let sanitized = EscapeSequenceSanitizer.sanitize(line)
        let transformed = applyCTOPrefixIfNeeded(to: sanitized)
        let trimmed = transformed.trimmingCharacters(in: .whitespacesAndNewlines)
        let isSystemRestoreInput = pendingSystemRestoreInputLine == trimmed
        if isSystemRestoreInput {
            pendingSystemRestoreInputLine = nil
        }
        guard !trimmed.isEmpty else {
            pendingCommandLine = nil
            promptSeenForPendingCommand = false
            commandFinishedNotified = false
            commandPendingDetection = false
            return
        }
        let resumeMetadata = AIResumeParser.extractMetadata(from: trimmed)
        if resumeMetadata == nil, !isSystemRestoreInput {
            suppressWaitingInputFallbackUntilNextUserCommand = false
            deliveredSystemResumePrefillSinceLastUserCommand = false
        }

        // Security: check if the PTY has echo disabled (password prompt, passphrase, etc.)
        // If so, mark as sensitive to prevent recording in history.
        let echoDisabled = activeTerminalView?.isPtyEchoDisabled ?? false
        if !isSystemRestoreInput {
            CommandHistoryManager.shared.recordCommand(trimmed, tabID: tabIdentifier, isSensitive: echoDisabled)
        }
        guard !echoDisabled else {
            Log.trace("Skipping echo-disabled input from persistence and shell event tracking")
            return
        }

        let persistedCommand = SensitiveInputGuard.sanitizedCommandForPersistence(trimmed)
        pendingCommandLine = persistedCommand

        // When the shell sends OSC 133 markers, it handles the command lifecycle
        // authoritatively — skip the heuristic echo-based detection.
        if !hasShellIntegration {
            hasPendingCommand = true
            promptSeenForPendingCommand = false
            commandFinishedNotified = false
            isAtPrompt = false
            shellEventDetector.commandStarted(command: persistedCommand, in: currentDirectory)
            onPermissionResolved?()
        }
        trackAIResumeMetadata(from: trimmed)
        updateActiveAppName(from: trimmed)
        // Command-based detection has had its chance — release the output detection gate.
        commandPendingDetection = false
        if !isSystemRestoreInput {
            noteAIInputTimingIfNeeded(for: trimmed)
            recordInputLineIfNeeded()
            trackSemanticCommand(trimmed)
            recordDangerousCommandLineIfNeeded(trimmed)
        } else {
            clearPendingAITiming()
            clearWaitingInputFallbackTracking()
            Log.info(
                "Ignoring system restore input for tab=\(tabIdentifier); keeping waiting_input fallback suppressed until explicit user command"
            )
        }
        guard let targetRaw = cdTarget(from: trimmed) else { return }

        var target: String
        if targetRaw.isEmpty {
            target = RuntimeIsolation.homePath()
        } else {
            target = targetRaw
        }

        if target.hasPrefix("~") {
            target = RuntimeIsolation.expandTilde(in: target)
        }

        let resolved: String
        if target.hasPrefix("/") {
            resolved = String(target)
        } else {
            let base = URL(fileURLWithPath: currentDirectory)
            resolved = base.appendingPathComponent(String(target)).standardized.path
        }

        updateCurrentDirectory(resolved)
    }

    func markIdleIfNeeded() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Don't transition from waitingForInput - user needs to respond
            guard status == .running || status == .stuck else { return }
            guard hasPendingCommand else { return }

            let latestActivity = max(lastInputAt, lastOutputAt)
            let latestIdleFor = Date().timeIntervalSince(latestActivity)
            let runningFor = Date().timeIntervalSince(commandStartedAt)

            // When OSC 133 is active, the shell tells us exactly when commands
            // finish — skip the timeout-based "stuck" and "fallback completion" heuristics.
            if !hasShellIntegration {
                // Check for "stuck" - running for too long without recent output
                if status == .running, runningFor >= stuckSeconds {
                    let outputIdleFor = Date().timeIntervalSince(lastOutputAt)
                    if outputIdleFor >= stuckSeconds {
                        status = .stuck
                        let cmd = (pendingCommandLine ?? "").prefix(60)
                        Log.info("Command marked as stuck after \(Int(runningFor))s tab=\(tabIdentifier) cmd=\(cmd)")
                        return
                    }
                }

                // Fall back after a long idle if prompt updates are missing.
                if !promptSeenForPendingCommand {
                    if latestIdleFor >= fallbackCompletionSeconds {
                        promptSeenForPendingCommand = true
                        if !commandFinishedNotified {
                            commandFinishedNotified = true
                            shellEventDetector.commandFinished(exitCode: nil, command: pendingCommandLine)
                        }
                        Log.info("Fallback completion after \(Int(latestIdleFor))s without prompt")
                    } else {
                        return
                    }
                }
            }

            // Check for idle - no activity for idleSeconds
            guard latestIdleFor >= idleSeconds else { return }

            if activeAppName != nil || effectiveAIProvider != nil || lastDetectedAppName != nil {
                status = .done
            } else {
                status = .idle
            }
            hasPendingCommand = false
            promptSeenForPendingCommand = false
            pendingCommandLine = nil

            // The 3-second idle transition is a UI state change, not a meaningful
            // event. Don't record or notify — actual "finished" events come from
            // OSC 133 D, the 60s fallback, or the session resolver's active→idle bridge.
            Log.trace("Command idle for \(Int(latestIdleFor))s in \(notificationTabName)"
            )
        }
    }

    private func updateActiveAppName(from commandLine: String) {
        let persistedCommand = SensitiveInputGuard.sanitizedCommandForPersistence(commandLine)
        let loggedCommand = persistedCommand ?? SensitiveInputGuard.redactedPlaceholder

        if let match = CommandDetection.detectLaunchableApp(
            from: commandLine,
            currentDirectory: currentDirectory,
            searchPath: launchPATHValue()
        ) {
            aiDetection.handleCommand(appName: match)
            activeAppName = match
            updateLastDetectedApp(match)
            Log.info("AI detected: \(match) from command '\(loggedCommand.prefix(50))'")
            startAILoggingIfNeeded(toolName: match, commandLine: persistedCommand)
            return
        }

        // Check for dev server command
        if let devServerName = CommandDetection.detectDevServer(from: commandLine) {
            Log.trace("Dev server command detected: \(devServerName) from '\(loggedCommand.prefix(50))'")
            devServerMonitor.setCommandHint(devServerName)
        }

        // Custom detection rules (substring match on command line)
        let lowercasedLine = commandLine.lowercased()
        for rule in FeatureSettings.shared.customAIDetectionRules {
            let pattern = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if pattern.isEmpty { continue }
            if lowercasedLine.contains(pattern) {
                let name = rule.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                let displayName = name.isEmpty ? "Custom AI" : name
                aiDetection.handleCommand(appName: displayName)
                activeAppName = displayName
                updateLastDetectedApp(displayName)
                startAILoggingIfNeeded(toolName: displayName, commandLine: persistedCommand)
                return
            }
        }

        if activeAppName != nil, isExitCommand(commandLine) {
            // Keep lastAIProvider/lastAISessionId so tab restore can resume the
            // most recent session for this pane even after shell-level exits.
            Log.trace("Clearing active app due to exit command input.")
            aiDetection.handleExit()
            activeAppName = nil
        }
    }

    func trackAIResumeMetadata(from commandLine: String) {
        let trimmed = commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let metadata = AIResumeParser.extractMetadata(from: trimmed) {
            let previousSessionId = normalizedStoredAISessionId()
            lastAIProvider = metadata.provider
            lastAISessionId = metadata.sessionId
            lastAISessionIdentitySource = .explicit
            if previousSessionId != metadata.sessionId {
                agentStartedAt = nil
                lastExitCode = nil
                lastExitAt = nil
            }
            // Update telemetry run with discovered session ID
            if !metadata.sessionId.isEmpty {
                TelemetryRecorder.shared.updateSessionID(tabID: tabIdentifier, sessionID: metadata.sessionId)
            }
            return
        }

        if let detectedProvider = AIResumeParser.detectProvider(from: trimmed) {
            lastAIProvider = detectedProvider
            lastAISessionId = nil
            lastAISessionIdentitySource = nil
        }
    }

    /// Restores AI metadata from persisted tab state without waiting for user input.
    /// This keeps explicit session metadata stable across restoration boundaries and
    /// prevents fallback logic from collapsing multiple tabs into one inferred session.
    func restoreAIMetadata(
        provider: String?,
        sessionId: String?,
        sessionIdSource: AISessionIdentitySource? = nil,
        launchCommand: String? = nil,
        startedAt: Date? = nil,
        lastInputAt: Date? = nil,
        lastOutputAt: Date? = nil,
        lastStatus: CommandStatus? = nil,
        lastExitCode: Int? = nil,
        lastExitAt: Date? = nil
    ) {
        let normalizedProvider = AIResumeParser.normalizeProviderName(
            provider ?? ""
        )
        let restoredDisplayName = Self.displayName(fromProvider: normalizedProvider)
        if let name = restoredDisplayName {
            aiDetection.handleRestore(appName: name)
        }
        activeAppName = restoredDisplayName
        lastDetectedAppName = nil
        lastAIProvider = normalizedProvider
        suppressWaitingInputFallbackUntilNextUserCommand = restoredDisplayName != nil
        pendingWaitingInputFallbackArmed = false
        pendingWaitingInputFallbackSawLiveOutput = false
        if restoredDisplayName != nil {
            Log.info(
                "Restored AI metadata for tab=\(tabIdentifier); suppressing prompt waiting_input fallback until explicit user command"
            )
        }

        agentStartedAt = startedAt
        if let lastInputAt {
            self.lastInputAt = lastInputAt
        }
        if let lastOutputAt {
            self.lastOutputAt = lastOutputAt
        }
        lastAgentLaunchCommand = launchCommand
        if let lastStatus {
            status = lastStatus
        }
        self.lastExitCode = lastExitCode
        self.lastExitAt = lastExitAt

        if let sessionId {
            let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
            if AIResumeParser.isValidSessionId(trimmed)
                || (sessionIdSource == .synthetic && trimmed.hasPrefix("synth:")) {
                lastAISessionId = trimmed
            } else {
                lastAISessionId = nil
            }
            lastAISessionIdentitySource = lastAISessionId == nil ? nil : (sessionIdSource ?? .explicit)
            return
        }

        lastAISessionId = nil
        lastAISessionIdentitySource = nil
    }

    private func noteAgentLaunch(toolName: String, commandLine: String?) {
        let normalizedProvider = AIResumeParser.normalizeProviderName(toolName)
            ?? AIResumeParser.detectProvider(from: toolName)
        let hasConcreteSessionIdentity = normalizedStoredAISessionId() != nil
            && lastAISessionIdentitySource != .synthetic

        if !hasConcreteSessionIdentity || agentStartedAt == nil {
            agentStartedAt = Date()
        }
        if let normalizedProvider {
            lastAIProvider = normalizedProvider
        }
        if let commandLine, !commandLine.isEmpty {
            lastAgentLaunchCommand = commandLine
        }
        lastExitCode = nil
        lastExitAt = nil
        if status == .done {
            status = .running
        }
    }

    private func shouldAllowRestoredProviderOverride(
        matchedAppName: String?,
        authoritativeAppName: String?
    ) -> Bool {
        guard aiDetection.isRestored,
              let matchedProvider = AIResumeParser.normalizeProviderName(matchedAppName ?? ""),
              let restoredProvider = AIResumeParser.normalizeProviderName(authoritativeAppName ?? "")
        else {
            return false
        }

        guard matchedProvider != restoredProvider else {
            return false
        }

        // Only allow live output to reclaim a restored tab when the restored
        // metadata no longer has a concrete session anchor. This fixes stale
        // provider badges without reintroducing arbitrary output hijacking.
        return effectiveAISessionId == nil
    }

    private func isExitCommand(_ commandLine: String) -> Bool {
        let trimmed = commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lowered = trimmed.lowercased()
        let exitCommands = ["exit", "logout", "quit"]
        for command in exitCommands {
            if lowered == command {
                return true
            }
            guard lowered.hasPrefix(command) else { continue }
            let nextIndex = lowered.index(lowered.startIndex, offsetBy: command.count)
            guard nextIndex < lowered.endIndex else { continue }
            let nextChar = lowered[nextIndex]
            if nextChar.isWhitespace || nextChar == ";" || nextChar == "&" || nextChar == "|" {
                return true
            }
        }
        return false
    }

    private func cdTarget(from commandLine: String) -> String? {
        let tokens = CommandDetection.tokenize(commandLine)
        guard let cmdIndex = CommandDetection.commandTokenIndex(from: tokens) else { return nil }
        let command = CommandDetection.normalizeToken(tokens[cmdIndex])
        guard command == "cd" else { return nil }

        let arguments = tokens[(cmdIndex + 1)...]
        guard let firstArg = arguments.first else { return "" }
        if firstArg == "-" {
            return nil
        }
        return firstArg
    }

    private func recordInputLineIfNeeded() {
        guard let view = activeTerminalView else { return }
        // Record input lines for semantic search or any active AI agent
        if FeatureSettings.shared.isSemanticSearchEnabled || activeAppName != nil {
            view.recordInputLine()
        }
    }

    private func noteAIInputTimingIfNeeded(for commandLine: String) {
        let detectedApp = CommandDetection.detectLaunchableApp(
            from: commandLine,
            currentDirectory: currentDirectory,
            searchPath: launchPATHValue()
        )
        let measurementKind = LatencyMeasurementSemantics.inputMeasurementKind(
            hasBackgroundAIContext: hasBackgroundRenderingAIContext,
            detectedLaunchableApp: detectedApp
        )
        guard measurementKind == .aiRoundTrip else {
            clearPendingAITiming()
            clearWaitingInputFallbackTracking()
            return
        }

        // Keep terminal responsiveness metrics focused on local PTY/UI lag.
        // AI sessions already log their own input-to-first-output timing separately.
        clearPendingInputLatencyMeasurement()

        pendingWaitingInputFallbackArmed = AIResumeParser.extractMetadata(from: commandLine) == nil
        pendingWaitingInputFallbackSawLiveOutput = false
        pendingAITimingInputAt = Date()
        pendingAITimingInputChars = commandLine.count
        let app = aiDisplayAppName
            ?? detectedApp
            ?? Self.displayName(fromProvider: effectiveAIProvider)
            ?? "unknown"
        Log.info(
            "AI timing: input submitted tab=\(tabIdentifier) app=\(app) provider=\(effectiveAIProvider ?? "nil") sessionId=\(effectiveAISessionId ?? "nil") chars=\(commandLine.count) status=\(effectiveStatus.rawValue) prompt=\(effectiveIsAtPrompt)"
        )
    }

    private func noteAIFirstOutputIfNeeded(bytes: Int, at now: Date) {
        guard let inputAt = pendingAITimingInputAt else { return }

        let elapsed = now.timeIntervalSince(inputAt)
        guard elapsed >= 0, elapsed <= aiTimingWindowSeconds else {
            clearPendingAITiming()
            return
        }

        let app = aiDisplayAppName
            ?? Self.displayName(fromProvider: effectiveAIProvider)
            ?? "unknown"
        Log.info(
            "AI timing: first output tab=\(tabIdentifier) app=\(app) provider=\(effectiveAIProvider ?? "nil") sessionId=\(effectiveAISessionId ?? "nil") inputChars=\(pendingAITimingInputChars) bytes=\(bytes) afterMs=\(Int((elapsed * 1000).rounded())) status=\(effectiveStatus.rawValue) prompt=\(effectiveIsAtPrompt)"
        )
        clearPendingAITiming()
    }

    private func clearPendingAITiming() {
        pendingAITimingInputAt = nil
        pendingAITimingInputChars = 0
    }

    private func clearWaitingInputFallbackTracking() {
        pendingWaitingInputFallbackArmed = false
        pendingWaitingInputFallbackSawLiveOutput = false
    }

    private func recordDangerousCommandLineIfNeeded(_ commandLine: String) {
        let settings = FeatureSettings.shared
        guard CommandRiskDetection.isRisky(commandLine: commandLine, patterns: settings.dangerousCommandPatterns) else { return }
        guard let row = currentBufferRow() else { return }
        dangerousCommandTracker.record(row: row)
        if settings.dangerousCommandHighlightScope == .allOutputs {
            highlightView?.scheduleDisplay()
        }
    }

    private func recordDangerousOutputIfNeeded() {
        let settings = FeatureSettings.shared
        let scope = settings.dangerousCommandHighlightScope
        guard scope != .none else { return }
        if scope == .aiOutputs, activeAppName == nil { return }
        scheduleDangerousOutputHighlight()
    }

    func scheduleHighlightAfterScroll() {
        guard highlightView != nil else { return }
        scrollHighlightWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.highlightView?.scheduleDisplay()
        }
        scrollHighlightWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + scrollHighlightDebounceSeconds, execute: work)
    }

    private func scheduleDangerousOutputHighlight() {
        guard highlightView != nil else { return }
        let (idleDelay, maxInterval) = dangerousOutputHighlightTiming()
        let now = Date()
        let sinceLastRun = now.timeIntervalSince(dangerousOutputHighlightLastRun)
        let delay: TimeInterval = sinceLastRun >= maxInterval
            ? 0
            : idleDelay

        dangerousOutputHighlightWorkItem?.cancel()
        let expectedFireAt = CFAbsoluteTimeGetCurrent() + delay
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let congestionMs = max(0, (CFAbsoluteTimeGetCurrent() - expectedFireAt) * 1000.0)
            dangerousHighlightSamples.append(Int(congestionMs.rounded()))
            dangerousHighlightSampleCount += 1
            dangerousHighlightTotalMs += congestionMs
            dangerousHighlightDelayMs = Int(congestionMs.rounded())
            dangerousHighlightAverageMs = dangerousHighlightSamples.recentAverage()
            dangerousOutputHighlightLastRun = Date()
            maybeLogLatencySpike(
                kind: "highlight",
                elapsedMs: congestionMs,
                averageMs: dangerousHighlightAverageMs,
                samples: dangerousHighlightSamples,
                thresholdMs: highlightLagLogThresholdMs,
                lastLoggedAt: &lastHighlightLagLogAt
            )
            refreshCachedDangerousOutputRows()
            highlightView?.scheduleDisplay()
        }
        dangerousOutputHighlightWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func dangerousOutputHighlightTiming() -> (idleDelay: TimeInterval, maxInterval: TimeInterval) {
        let settings = FeatureSettings.shared
        let idleMs = max(0, min(settings.dangerousOutputHighlightIdleDelayMs, 5000))
        let maxMs = max(250, min(settings.dangerousOutputHighlightMaxIntervalMs, 10000))
        let maxInterval = max(maxMs, idleMs)
        var idleDelay = TimeInterval(idleMs) / 1000.0
        var maxIntervalSeconds = TimeInterval(maxInterval) / 1000.0

        if outputBurstActive {
            // Cap highlight updates to ~2 Hz during sustained output.
            idleDelay = max(idleDelay, 0.5)
            maxIntervalSeconds = max(maxIntervalSeconds, 0.5)
        }
        if isCpuSaturated() {
            // Be more conservative when the UI is already struggling.
            idleDelay = max(idleDelay, 1.0)
            maxIntervalSeconds = max(maxIntervalSeconds, 1.0)
        }

        return (idleDelay, maxIntervalSeconds)
    }

    private func shouldUseLowPowerHighlights() -> Bool {
        guard FeatureSettings.shared.dangerousOutputHighlightLowPowerEnabled else { return false }
        return outputBurstActive || isCpuSaturated()
    }

    private func isCpuSaturated() -> Bool {
        // Only use input/output latency — these measure real main-thread congestion.
        // Highlight latency includes its own throttle delay, creating a feedback loop
        // where isCpuSaturated() → 1000ms delay → high average → isCpuSaturated() forever.
        let inputLag = inputLatencyAverageMs ?? inputLatencyMs ?? 0
        let outputLag = outputLatencyAverageMs ?? outputLatencyMs ?? 0
        let maxLag = max(inputLag, outputLag)
        return maxLag >= 80
    }

    private func trackSemanticCommand(_ command: String) {
        guard FeatureSettings.shared.isSemanticSearchEnabled else { return }
        guard let row = currentBufferRow() else { return }
        let persistedCommand = SensitiveInputGuard.sanitizedCommandForPersistence(command) ?? command
        semanticDetector.commandStarted(persistedCommand, atRow: row)
    }

    private func currentBufferRow() -> Int? {
        guard let view = activeTerminalView else { return nil }
        return view.currentAbsoluteRow
    }

    func dangerousCommandRowsVisible(top: Int, bottom: Int) -> [Int] {
        dangerousCommandTracker.visibleRows(top: top, bottom: bottom)
    }

    func dangerousOutputRowsVisible(top: Int, bottom: Int) -> [Int] {
        let settings = FeatureSettings.shared
        let scope = settings.dangerousCommandHighlightScope
        guard scope != .none else { return [] }
        if scope == .aiOutputs, activeAppName == nil { return [] }
        guard let view = activeTerminalView else { return [] }
        let cols = view.terminalCols
        guard cols > 0 else { return [] }

        let token = FeatureProfiler.shared.begin(.dangerScan, metadata: "rows \(top)-\(bottom)")
        defer { FeatureProfiler.shared.end(token) }

        let start = max(0, top)
        let end = max(start, bottom)
        let visibleCount = end - start + 1
        let lowPowerActive = shouldUseLowPowerHighlights()
        let maxComputations: Int
        if lowPowerActive {
            maxComputations = min(16, max(6, visibleCount / 3))
        } else {
            maxComputations = Int.max
        }
        var computedCount = 0
        var rows: [Int] = []
        rows.reserveCapacity(min(32, end - start + 1))

        if outputRiskCache.count > outputRiskCacheMaxEntries {
            outputRiskCache.removeAll(keepingCapacity: true)
        }
        let version = outputRiskCacheVersion
        let dirtyRange = dirtyOutputRange

        func lineText(for row: Int) -> String {
            return view.getLineText(absoluteRow: row)
        }

        for row in start ... end {
            let isDirty = dirtyRange?.contains(row) ?? false
            if !isDirty, let cached = outputRiskCache[row], cached.version == version {
                if cached.isRisk {
                    rows.append(row)
                }
                continue
            }

            if lowPowerActive, computedCount >= maxComputations {
                continue
            }

            let text = lineText(for: row)
            let sanitized = EscapeSequenceSanitizer.sanitize(text)
            var isRisk = CommandRiskDetection.isRisky(commandLine: sanitized, patterns: settings.dangerousCommandPatterns)
            if isRisk {
                outputRiskCache[row] = (version: version, isRisk: true)
                rows.append(row)
                computedCount += 1
                continue
            }

            if !lowPowerActive {
                let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count >= cols - 1, row + 1 <= end {
                    let nextText = lineText(for: row + 1)
                    let combined = trimmed + EscapeSequenceSanitizer.sanitize(nextText)
                    if CommandRiskDetection.isRisky(commandLine: combined, patterns: settings.dangerousCommandPatterns) {
                        isRisk = true
                        outputRiskCache[row] = (version: version, isRisk: true)
                        outputRiskCache[row + 1] = (version: version, isRisk: true)
                        rows.append(row)
                        rows.append(row + 1)
                        computedCount += 1
                        continue
                    }
                }
            }

            outputRiskCache[row] = (version: version, isRisk: isRisk)
            computedCount += 1
        }

        if let dirtyRange {
            if start <= dirtyRange.lowerBound, end >= dirtyRange.upperBound {
                dirtyOutputRange = nil
            } else if dirtyRange.lowerBound < start, dirtyRange.upperBound <= end {
                let newUpper = start - 1
                dirtyOutputRange = newUpper >= dirtyRange.lowerBound ? dirtyRange.lowerBound ... newUpper : nil
            } else if dirtyRange.lowerBound >= start, dirtyRange.upperBound > end {
                let newLower = end + 1
                dirtyOutputRange = newLower <= dirtyRange.upperBound ? newLower ... dirtyRange.upperBound : nil
            }
        }

        return rows
    }

    /// Refreshes the cached set of dangerous output rows using the current viewport.
    private func refreshCachedDangerousOutputRows() {
        guard let rustView = activeTerminalView as? RustTerminalView else {
            cachedDangerousOutputRowSet = []
            return
        }
        let top = rustView.renderTopVisibleRow
        let bottom = top + rustView.renderRows - 1
        cachedDangerousOutputRowSet = Set(dangerousOutputRowsVisible(top: top, bottom: bottom))
    }

    /// Returns cached dangerous output rows within the given viewport range.
    private func cachedDangerousOutputRows(top: Int, bottom: Int) -> [Int] {
        cachedDangerousOutputRowSet.filter { $0 >= top && $0 <= bottom }
    }

    /// Combines input command rows and cached output rows into a viewport tint map.
    /// Called at 60fps from `syncGridToRenderer()` — uses only cheap lookups and cached data.
    func dangerousRowTints(top: Int, bottom: Int) -> [Int: NSColor] {
        let scope = FeatureSettings.shared.dangerousCommandHighlightScope
        guard scope != .none else { return [:] }
        let dangerColor = NSColor.systemRed.withAlphaComponent(0.50)
        var tints: [Int: NSColor] = [:]
        // Input rows: always included (cheap set lookup)
        for row in dangerousCommandTracker.visibleRows(top: top, bottom: bottom) {
            tints[row] = dangerColor
        }
        // Output rows: use cached results only (no expensive scanning here)
        if scope == .allOutputs || (scope == .aiOutputs && activeAppName != nil) {
            for row in cachedDangerousOutputRows(top: top, bottom: bottom) {
                tints[row] = dangerColor
            }
        }
        return tints
    }

}
