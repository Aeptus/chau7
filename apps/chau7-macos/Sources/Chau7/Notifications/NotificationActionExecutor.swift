import Foundation
import AppKit
import Chau7Core

/// Protocol for UI actions triggered by the notification system.
/// Replaces 5 separate closure handlers with a single conformance point.
@MainActor protocol NotificationActionDelegate: AnyObject {
    func focusTab(for target: TabTarget)
    @discardableResult func styleTab(for target: TabTarget, preset: String, config: [String: String]) -> UUID?
    func badgeTab(for target: TabTarget, text: String, color: String)
    func insertSnippet(id: String, for target: TabTarget, autoExecute: Bool)
    func flashMenuBar(duration: Int, animate: Bool)
}

/// Executes notification actions in response to events
@MainActor
final class NotificationActionExecutor {
    static let shared = NotificationActionExecutor()

    // MARK: - Dependencies (injected from app)

    /// Strong reference is safe — the adapter holds only weak refs to the actual UI objects.
    var delegate: NotificationActionDelegate?

    // MARK: - Time Tracking State

    private var activeTimers: [String: Date] = [:]

    // MARK: - Tab Style Auto-Clear Tracking

    /// Tracks pending auto-clear work items per tab ID to allow cancellation.
    /// Keyed by tab UUID (not tool name) so timers for different tabs running the same tool don't collide.
    /// All access must be on the main queue.
    private var pendingStyleClears: [UUID: DispatchWorkItem] = [:]

    /// Held to prevent the flash window from being deallocated during animation
    private var flashWindow: NSWindow?
    /// Held to prevent the speech synthesizer from being deallocated before speech completes
    private var speechSynthesizer: NSSpeechSynthesizer?

    private init() {}

    // MARK: - Main Entry Point

    func execute(actions: [NotificationActionConfig], for event: AIEvent) {
        for actionConfig in actions where actionConfig.enabled {
            executeAction(actionConfig, for: event)
        }
    }

    private func executeAction(_ config: NotificationActionConfig, for event: AIEvent) {
        let context = ActionContext(event: event, config: config)

        switch config.actionType {
        // Basic
        case .showNotification:
            executeShowNotification(context)
        case .playSound:
            executePlaySound(context)
        case .focusWindow:
            executeFocusWindow(context)
        case .dockBounce:
            executeDockBounce(context)
        case .badgeTab:
            executeBadgeTab(context)
        case .styleTab:
            executeStyleTab(context)
        // Automation
        case .runScript:
            executeRunScript(context)
        case .runShortcut:
            executeRunShortcut(context)
        case .executeSnippet:
            executeExecuteSnippet(context)
        // Integration
        case .webhook:
            executeWebhook(context)
        case .sendSlack:
            executeSendSlack(context)
        case .sendDiscord:
            executeSendDiscord(context)
        // DevOps
        case .dockerBump:
            executeDockerBump(context)
        case .dockerCompose:
            executeDockerCompose(context)
        case .kubernetesRollout:
            executeKubernetesRollout(context)
        // Productivity
        case .copyToClipboard:
            executeCopyToClipboard(context)
        case .writeToFile:
            executeWriteToFile(context)
        case .openURL:
            executeOpenURL(context)
        case .gitCommit:
            executeGitCommit(context)
        // Accessibility
        case .voiceAnnounce:
            executeVoiceAnnounce(context)
        case .flashScreen:
            executeFlashScreen(context)
        case .menuBarAlert:
            executeMenuBarAlert(context)
        // Time Tracking
        case .startTimer:
            executeStartTimer(context)
        case .stopTimer:
            executeStopTimer(context)
        case .logTime:
            executeLogTime(context)
        }
    }

    // MARK: - Action Context

    struct ActionContext {
        let event: AIEvent
        let config: NotificationActionConfig

        func configValue(_ key: String) -> String? {
            config.config[key]
        }

        func configBool(_ key: String, default defaultValue: Bool = false) -> Bool {
            config.configBool(key, default: defaultValue)
        }

        func configInt(_ key: String, default defaultValue: Int = 0) -> Int {
            config.configInt(key, default: defaultValue)
        }

        /// Replace template variables in a string
        func interpolate(_ template: String?) -> String {
            guard let template = template, !template.isEmpty else {
                return event.message
            }
            return template
                .replacingOccurrences(of: "${message}", with: event.message)
                .replacingOccurrences(of: "${type}", with: event.type)
                .replacingOccurrences(of: "${tool}", with: event.tool)
                .replacingOccurrences(of: "${source}", with: event.source.rawValue)
                .replacingOccurrences(of: "${timestamp}", with: event.ts)
                .replacingOccurrences(of: "${id}", with: event.id.uuidString)
        }

        /// Get event as JSON dictionary
        func eventJSON() -> [String: Any] {
            return [
                "id": event.id.uuidString,
                "source": event.source.rawValue,
                "type": event.type,
                "tool": event.tool,
                "message": event.message,
                "timestamp": event.ts
            ]
        }

        /// Environment variables for script execution
        func environmentVariables() -> [String: String] {
            return [
                "CHAU7_EVENT_ID": event.id.uuidString,
                "CHAU7_SOURCE": event.source.rawValue,
                "CHAU7_TYPE": event.type,
                "CHAU7_TOOL": event.tool,
                "CHAU7_MESSAGE": event.message,
                "CHAU7_TIMESTAMP": event.ts
            ]
        }
    }

    // MARK: - Basic Actions

    private func executeShowNotification(_ ctx: ActionContext) {
        let customTitle = ctx.interpolate(ctx.configValue("customTitle"))
        let customBody = ctx.interpolate(ctx.configValue("customBody"))
        let title = customTitle.isEmpty ? ctx.event.notificationTitle(toolOverride: nil) : customTitle
        let body = customBody.isEmpty ? ctx.event.notificationBody : customBody
        NotificationManager.shared.dispatchActionNotification(title: title, body: body, for: ctx.event)
    }

    private func executePlaySound(_ ctx: ActionContext) {
        let soundName = ctx.configValue("sound") ?? "default"
        let volume = Float(ctx.configInt("volume", default: 100)) / 100.0

        DispatchQueue.main.async {
            if soundName == "default" {
                NSSound.beep()
            } else if let sound = NSSound(named: NSSound.Name(soundName)) {
                sound.volume = volume
                sound.play()
            } else if let sound = NSSound(contentsOfFile: soundName, byReference: true) {
                sound.volume = volume
                sound.play()
            } else {
                // Try system sounds
                let systemSoundPath = "/System/Library/Sounds/\(soundName).aiff"
                if let sound = NSSound(contentsOfFile: systemSoundPath, byReference: true) {
                    sound.volume = volume
                    sound.play()
                } else {
                    Log.warn("Action playSound: Sound not found: \(soundName)")
                    NSSound.beep()
                }
            }
        }
    }

    private func executeFocusWindow(_ ctx: ActionContext) {
        let focusTab = ctx.configBool("focusTab", default: true)

        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)

            if focusTab {
                self?.delegate?.focusTab(for: ctx.event.tabTarget)
            }
        }
    }

    private func executeDockBounce(_ ctx: ActionContext) {
        let critical = ctx.configBool("critical", default: false)

        DispatchQueue.main.async {
            let attentionType: NSApplication.RequestUserAttentionType = critical ? .criticalRequest : .informationalRequest
            NSApp.requestUserAttention(attentionType)
            Log.info("Action dockBounce: Requested user attention (critical=\(critical))")
        }
    }

    private func executeBadgeTab(_ ctx: ActionContext) {
        let badgeText = ctx.configValue("badgeText") ?? "!"
        let badgeColor = ctx.configValue("badgeColor") ?? "red"

        DispatchQueue.main.async { [weak self] in
            self?.delegate?.badgeTab(for: ctx.event.tabTarget, text: badgeText, color: badgeColor)
        }
    }

    private func executeStyleTab(_ ctx: ActionContext) {
        let stylePreset = ctx.configValue("style") ?? "waiting"
        let config = ctx.config.config // Pass all config to handler
        let target = ctx.event.tabTarget
        let autoClearSeconds = ctx.configInt("autoClearSeconds", default: 0)

        // All pendingStyleClears access and delegate calls on main queue
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            let resolvedTabID = delegate?.styleTab(for: target, preset: stylePreset, config: config)

            // Key timers by resolved tab ID so different tabs running the same tool don't collide
            guard let resolvedTabID else { return }

            // Cancel any pending auto-clear for this specific tab
            pendingStyleClears[resolvedTabID]?.cancel()
            pendingStyleClears.removeValue(forKey: resolvedTabID)

            if autoClearSeconds > 0 {
                // Use resolved tab ID in the clear target so the timer hits the exact tab
                let clearTarget = TabTarget(tool: target.tool, directory: target.directory, tabID: resolvedTabID)
                let workItem = DispatchWorkItem { [weak self] in
                    self?.pendingStyleClears.removeValue(forKey: resolvedTabID)
                    self?.delegate?.styleTab(for: clearTarget, preset: "clear", config: [:])
                }
                pendingStyleClears[resolvedTabID] = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(autoClearSeconds), execute: workItem)
            }
        }
    }

    // MARK: - Automation Actions

    private func executeRunScript(_ ctx: ActionContext) {
        guard let script = ctx.configValue("script"), !script.isEmpty else {
            Log.warn("Action runScript: No script provided")
            return
        }

        let shell = ctx.configValue("shell") ?? "/bin/zsh"
        let timeout = ctx.configInt("timeout", default: 30)
        let workingDir = ctx.configValue("workingDir")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // Pass script directly to shell — do NOT interpolate event data into the script.
        // Event data is available only via environment variables ($CHAU7_MESSAGE, etc.)
        process.arguments = ["-c", script]
        process.environment = ProcessInfo.processInfo.environment.merging(ctx.environmentVariables()) { _, new in new }

        if let dir = workingDir, !dir.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: RuntimeIsolation.expandTilde(in: dir))
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()

            // Set up timeout
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeout)) {
                if process.isRunning {
                    Log.warn("Action runScript: Timeout after \(timeout)s, terminating")
                    process.terminate()
                }
            }

            // Non-blocking — terminationHandler fires on completion
            process.terminationHandler = { proc in
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if proc.terminationStatus != 0 {
                    Log.warn("Action runScript: Exit code \(proc.terminationStatus), output: \(output.prefix(500))")
                } else {
                    Log.info("Action runScript: Completed successfully")
                }
            }
        } catch {
            Log.error("Action runScript: Failed to execute: \(error.localizedDescription)")
        }
    }

    private func executeRunShortcut(_ ctx: ActionContext) {
        guard let shortcutName = ctx.configValue("shortcutName"), !shortcutName.isEmpty else {
            Log.warn("Action runShortcut: No shortcut name provided")
            return
        }

        let passEventData = ctx.configBool("passEventData", default: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", shortcutName]

        // Pass event data via stdin pipe instead of shell string interpolation
        let inputPipe: Pipe?
        if passEventData {
            inputPipe = Pipe()
            process.standardInput = inputPipe
        } else {
            inputPipe = nil
        }

        do {
            try process.run()

            // Write JSON event data to stdin after process starts
            if let inputPipe = inputPipe,
               let jsonData = try? JSONSerialization.data(withJSONObject: ctx.eventJSON()) {
                inputPipe.fileHandleForWriting.write(jsonData)
                inputPipe.fileHandleForWriting.closeFile()
            }

            process.terminationHandler = { proc in
                if proc.terminationStatus != 0 {
                    Log.warn("Action runShortcut: '\(shortcutName)' exited with \(proc.terminationStatus)")
                } else {
                    Log.info("Action runShortcut: Executed '\(shortcutName)'")
                }
            }
        } catch {
            Log.error("Action runShortcut: Failed: \(error.localizedDescription)")
        }
    }

    private func executeExecuteSnippet(_ ctx: ActionContext) {
        guard let snippetId = ctx.configValue("snippetId"), !snippetId.isEmpty else {
            Log.warn("Action executeSnippet: No snippet ID provided")
            return
        }

        let autoExecute = ctx.configBool("autoExecute", default: false)

        DispatchQueue.main.async { [weak self] in
            self?.delegate?.insertSnippet(id: snippetId, for: ctx.event.tabTarget, autoExecute: autoExecute)
        }
    }

    // MARK: - Integration Actions

    private func executeWebhook(_ ctx: ActionContext) {
        guard let urlString = ctx.configValue("url"), let url = URL(string: urlString) else {
            Log.warn("Action webhook: Invalid URL")
            return
        }

        let method = ctx.configValue("method") ?? "POST"

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Chau7/1.0", forHTTPHeaderField: "User-Agent")

        // Parse custom headers
        if let headersJson = ctx.configValue("headers"),
           let headersData = headersJson.data(using: .utf8),
           let headers = try? JSONSerialization.jsonObject(with: headersData) as? [String: String] {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        // Build payload
        let payload: [String: Any]
        if let customPayload = ctx.configValue("customPayload"), !customPayload.isEmpty,
           let customData = customPayload.data(using: .utf8),
           let custom = try? JSONSerialization.jsonObject(with: customData) as? [String: Any] {
            payload = custom
        } else {
            payload = ctx.eventJSON()
        }

        if method != "GET" {
            request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        }

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error {
                Log.error("Action webhook: Failed: \(error.localizedDescription)")
            } else if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode >= 200, httpResponse.statusCode < 300 {
                    Log.info("Action webhook: Success (\(httpResponse.statusCode))")
                } else {
                    Log.warn("Action webhook: HTTP \(httpResponse.statusCode)")
                }
            }
        }.resume()
    }

    private func executeSendSlack(_ ctx: ActionContext) {
        guard let webhookUrl = ctx.configValue("webhookUrl"), let url = URL(string: webhookUrl) else {
            Log.warn("Action sendSlack: Invalid webhook URL")
            return
        }

        let username = ctx.configValue("username") ?? "Chau7"
        let emoji = ctx.configValue("emoji") ?? ":computer:"
        let channel = ctx.configValue("channel")

        var payload: [String: Any] = [
            "username": username,
            "icon_emoji": emoji,
            "text": ctx.interpolate("*\(ctx.event.type.capitalized)*: \(ctx.event.message)")
        ]

        if let channel = channel, !channel.isEmpty {
            payload["channel"] = channel
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        URLSession.shared.dataTask(with: request) { _, _, error in
            if let error = error {
                Log.error("Action sendSlack: Failed: \(error.localizedDescription)")
            } else {
                Log.info("Action sendSlack: Message sent")
            }
        }.resume()
    }

    private func executeSendDiscord(_ ctx: ActionContext) {
        guard let webhookUrl = ctx.configValue("webhookUrl"), let url = URL(string: webhookUrl) else {
            Log.warn("Action sendDiscord: Invalid webhook URL")
            return
        }

        let username = ctx.configValue("username") ?? "Chau7"
        let avatarUrl = ctx.configValue("avatarUrl")

        var payload: [String: Any] = [
            "username": username,
            "content": ctx.interpolate("**\(ctx.event.type.capitalized)**: \(ctx.event.message)")
        ]

        if let avatar = avatarUrl, !avatar.isEmpty {
            payload["avatar_url"] = avatar
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        URLSession.shared.dataTask(with: request) { _, _, error in
            if let error = error {
                Log.error("Action sendDiscord: Failed: \(error.localizedDescription)")
            } else {
                Log.info("Action sendDiscord: Message sent")
            }
        }.resume()
    }

    // MARK: - DevOps Actions

    private func executeDockerBump(_ ctx: ActionContext) {
        guard let container = ctx.configValue("container"), !container.isEmpty else {
            Log.warn("Action dockerBump: No container specified")
            return
        }

        let operation = ctx.configValue("operation") ?? "restart"
        let dockerPath = ctx.configValue("dockerPath") ?? "/usr/local/bin/docker"

        switch operation {
        case "restart":
            runProcess(executable: dockerPath, arguments: ["restart", container], label: "dockerBump")
        case "stop":
            runProcess(executable: dockerPath, arguments: ["stop", container], label: "dockerBump")
        case "start":
            runProcess(executable: dockerPath, arguments: ["start", container], label: "dockerBump")
        case "rebuild":
            // Sequential operations — must run on background queue
            DispatchQueue.global(qos: .userInitiated).async {
                let steps: [(args: [String], desc: String)] = [
                    (["stop", container], "stop"),
                    (["rm", container], "remove"),
                    (["build", "-t", container, "."], "build"),
                    (["run", "-d", "--name", container, container], "run")
                ]
                for step in steps {
                    guard Self.runProcessSync(
                        executable: dockerPath,
                        arguments: step.args,
                        label: "dockerBump(\(step.desc))"
                    ) else { return }
                }
                Log.info("Action dockerBump: Rebuild completed successfully")
            }
        default:
            Log.warn("Action dockerBump: Unknown operation: \(operation)")
        }
    }

    private func executeDockerCompose(_ ctx: ActionContext) {
        guard let composePath = ctx.configValue("composePath"), !composePath.isEmpty else {
            Log.warn("Action dockerCompose: No compose file path specified")
            return
        }

        let operation = ctx.configValue("operation") ?? "restart"
        let services = ctx.configValue("services") ?? ""
        let dockerComposePath = ctx.configValue("dockerComposePath") ?? "/usr/local/bin/docker-compose"

        let expandedPath = RuntimeIsolation.expandTilde(in: composePath)
        let serviceArgs = services.isEmpty ? [] : services.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

        var args = ["-f", expandedPath]

        switch operation {
        case "up":
            args += ["up", "-d"] + serviceArgs
        case "down":
            args += ["down"] + serviceArgs
        case "restart":
            args += ["restart"] + serviceArgs
        case "build":
            args += ["build"] + serviceArgs
        case "pull":
            args += ["pull"] + serviceArgs
        default:
            Log.warn("Action dockerCompose: Unknown operation: \(operation)")
            return
        }

        runProcess(executable: dockerComposePath, arguments: args, label: "dockerCompose")
    }

    private func executeKubernetesRollout(_ ctx: ActionContext) {
        guard let deployment = ctx.configValue("deployment"), !deployment.isEmpty else {
            Log.warn("Action kubernetesRollout: No deployment specified")
            return
        }

        let namespace = ctx.configValue("namespace") ?? "default"
        let kubectlContext = ctx.configValue("context")
        let operation = ctx.configValue("operation") ?? "restart"
        let replicas = ctx.configValue("replicas")
        let kubectlPath = ctx.configValue("kubectlPath") ?? "/usr/local/bin/kubectl"

        var args: [String] = []
        if let kctx = kubectlContext, !kctx.isEmpty {
            args += ["--context", kctx]
        }
        args += ["-n", namespace]

        switch operation {
        case "restart":
            args += ["rollout", "restart", "deployment/\(deployment)"]
        case "scale":
            let replicaCount = replicas ?? "1"
            args += ["scale", "deployment/\(deployment)", "--replicas=\(replicaCount)"]
        case "status":
            args += ["rollout", "status", "deployment/\(deployment)"]
        default:
            Log.warn("Action kubernetesRollout: Unknown operation: \(operation)")
            return
        }

        runProcess(executable: kubectlPath, arguments: args, label: "kubernetesRollout")
    }

    // MARK: - Productivity Actions

    private func executeCopyToClipboard(_ ctx: ActionContext) {
        let content = ctx.interpolate(ctx.configValue("content"))

        DispatchQueue.main.async {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(content, forType: .string)
            Log.info("Action copyToClipboard: Copied \(content.count) characters")
        }
    }

    private func executeWriteToFile(_ ctx: ActionContext) {
        guard let filePath = ctx.configValue("filePath"), !filePath.isEmpty else {
            Log.warn("Action writeToFile: No file path specified")
            return
        }

        let format = ctx.configValue("format") ?? "text"
        let template = ctx.configValue("template")
        let expandedPath = RuntimeIsolation.expandTilde(in: filePath)

        let line: String
        switch format {
        case "json":
            if let data = try? JSONSerialization.data(withJSONObject: ctx.eventJSON()),
               let json = String(data: data, encoding: .utf8) {
                line = json
            } else {
                line = "{}"
            }
        case "csv":
            let fields = [ctx.event.ts, ctx.event.source.rawValue, ctx.event.type, ctx.event.tool, ctx.event.message]
                .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            line = fields.joined(separator: ",")
        default:
            if let tmpl = template, !tmpl.isEmpty {
                line = ctx.interpolate(tmpl)
            } else {
                line = "[\(ctx.event.ts)] \(ctx.event.type): \(ctx.event.message)"
            }
        }

        do {
            let fileURL = URL(fileURLWithPath: expandedPath)
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            // Atomic open-or-create+append via fopen "a" — no TOCTOU race
            guard let lineData = (line + "\n").data(using: .utf8) else { return }
            try Self.appendToFile(atPath: expandedPath, data: lineData)

            Log.info("Action writeToFile: Appended to \(filePath)")
        } catch {
            Log.error("Action writeToFile: Failed: \(error.localizedDescription)")
        }
    }

    private func executeOpenURL(_ ctx: ActionContext) {
        guard let urlTemplate = ctx.configValue("url"), !urlTemplate.isEmpty else {
            Log.warn("Action openURL: No URL specified")
            return
        }

        let urlString = ctx.interpolate(urlTemplate)
        guard let url = URL(string: urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? urlString) else {
            Log.warn("Action openURL: Invalid URL: \(urlString)")
            return
        }

        let browser = ctx.configValue("browser") ?? "default"

        DispatchQueue.main.async {
            if browser == "default" {
                NSWorkspace.shared.open(url)
            } else {
                let bundleId: String
                switch browser {
                case "safari": bundleId = "com.apple.Safari"
                case "chrome": bundleId = "com.google.Chrome"
                case "firefox": bundleId = "org.mozilla.firefox"
                case "arc": bundleId = "company.thebrowser.Browser"
                default: bundleId = browser
                }

                let config = NSWorkspace.OpenConfiguration()
                if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                    NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config)
                } else {
                    NSWorkspace.shared.open(url)
                }
            }
            Log.info("Action openURL: Opened \(url)")
        }
    }

    private func executeGitCommit(_ ctx: ActionContext) {
        let message = ctx.interpolate(ctx.configValue("message") ?? "Auto-commit: ${type}")
        let addAll = ctx.configBool("addAll", default: true)
        let push = ctx.configBool("push", default: false)
        let repoPath = ctx.configValue("repoPath")
        let gitPath = "/usr/bin/git"

        let workingDir: String?
        if let path = repoPath, !path.isEmpty {
            workingDir = RuntimeIsolation.expandTilde(in: path)
        } else {
            workingDir = nil
        }

        // Sequential git operations on background queue
        DispatchQueue.global(qos: .userInitiated).async {
            if addAll {
                guard Self.runProcessSync(
                    executable: gitPath,
                    arguments: ["add", "-A"],
                    currentDirectory: workingDir,
                    label: "gitCommit(add)"
                ) else { return }
            }

            guard Self.runProcessSync(
                executable: gitPath,
                arguments: ["commit", "-m", message],
                currentDirectory: workingDir,
                label: "gitCommit(commit)"
            ) else { return }

            if push {
                guard Self.runProcessSync(
                    executable: gitPath,
                    arguments: ["push"],
                    currentDirectory: workingDir,
                    label: "gitCommit(push)"
                ) else { return }
            }

            Log.info("Action gitCommit: Completed successfully")
        }
    }

    // MARK: - Accessibility Actions

    private func executeVoiceAnnounce(_ ctx: ActionContext) {
        let text = ctx.interpolate(ctx.configValue("text"))
        let voice = ctx.configValue("voice") ?? "default"
        let rate = ctx.configInt("rate", default: 175)

        DispatchQueue.main.async { [weak self] in
            let synthesizer = NSSpeechSynthesizer()

            if voice != "default" {
                synthesizer.setVoice(NSSpeechSynthesizer.VoiceName(rawValue: "com.apple.speech.synthesis.voice.\(voice.lowercased())"))
            }

            synthesizer.rate = Float(rate)
            // Hold reference to prevent deallocation before speech completes
            self?.speechSynthesizer = synthesizer
            synthesizer.startSpeaking(text)

            Log.info("Action voiceAnnounce: Speaking '\(text.prefix(50))...'")
        }
    }

    private func executeFlashScreen(_ ctx: ActionContext) {
        let colorName = ctx.configValue("color") ?? "white"
        let duration = ctx.configInt("duration", default: 200)
        let count = ctx.configInt("count", default: 2)

        let color: NSColor
        switch colorName {
        case "yellow": color = .yellow
        case "red": color = .red
        case "green": color = .green
        case "blue": color = .blue
        default: color = .white
        }

        Task { @MainActor [weak self] in
            guard let screen = NSScreen.main else { return }

            // Clean up any previous flash window
            self?.flashWindow?.orderOut(nil)

            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.level = .screenSaver
            window.backgroundColor = color
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            // Hold reference to prevent deallocation during animation
            self?.flashWindow = window
            Log.info("Action flashScreen: Flashing \(count) times")

            for _ in 0 ..< count {
                window.alphaValue = 0.5
                window.orderFront(nil)
                try? await Task.sleep(for: .milliseconds(duration))
                window.alphaValue = 0
                try? await Task.sleep(for: .milliseconds(100))
            }

            self?.flashWindow?.orderOut(nil)
            self?.flashWindow = nil
        }
    }

    private func executeMenuBarAlert(_ ctx: ActionContext) {
        let duration = ctx.configInt("duration", default: 5)
        let animate = ctx.configBool("animate", default: true)

        DispatchQueue.main.async { [weak self] in
            self?.delegate?.flashMenuBar(duration: duration, animate: animate)
            Log.info("Action menuBarAlert: Alert for \(duration) seconds")
        }
    }

    // MARK: - Time Tracking Actions

    private func executeStartTimer(_ ctx: ActionContext) {
        let timerName = ctx.interpolate(ctx.configValue("timerName") ?? ctx.event.tool)
        let project = ctx.configValue("project") ?? ""

        activeTimers[timerName] = Date()

        Log.info("Action startTimer: Started '\(timerName)' for project '\(project)'")
    }

    private func executeStopTimer(_ ctx: ActionContext) {
        let timerName = ctx.configValue("timerName")

        var stoppedTimer: (name: String, start: Date)?

        if let name = timerName, !name.isEmpty {
            if let start = activeTimers.removeValue(forKey: name) {
                stoppedTimer = (name, start)
            }
        } else if let (name, start) = activeTimers.first {
            activeTimers.removeValue(forKey: name)
            stoppedTimer = (name, start)
        }

        if let timer = stoppedTimer {
            let duration = Date().timeIntervalSince(timer.start)
            let minutes = Int(duration / 60)
            let seconds = Int(duration) % 60
            Log.info("Action stopTimer: Stopped '\(timer.name)' after \(minutes)m \(seconds)s")
        } else {
            Log.warn("Action stopTimer: No active timer found")
        }
    }

    private func executeLogTime(_ ctx: ActionContext) {
        let service = ctx.configValue("service") ?? "file"
        let description = ctx.interpolate(ctx.configValue("description") ?? "${type}: ${message}")

        switch service {
        case "file":
            let filePath = ctx.configValue("filePath") ?? "~/time-log.csv"
            let expandedPath = RuntimeIsolation.expandTilde(in: filePath)
            let entry = "\(ctx.event.ts),\"\(description.replacingOccurrences(of: "\"", with: "\"\""))\""

            do {
                let fileURL = URL(fileURLWithPath: expandedPath)
                let directory = fileURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

                // Use O_CREAT|O_EXCL to atomically write header only if file is new
                let fd = open(expandedPath, O_WRONLY | O_CREAT | O_EXCL, 0o644)
                if fd >= 0 {
                    let header = "timestamp,description\n"
                    header.withCString { _ = write(fd, $0, header.utf8.count) }
                    close(fd)
                }

                // Atomic append via fopen "a"
                if let entryData = (entry + "\n").data(using: .utf8) {
                    try Self.appendToFile(atPath: expandedPath, data: entryData)
                }
                Log.info("Action logTime: Logged to \(filePath)")
            } catch {
                Log.error("Action logTime: Failed to write file: \(error.localizedDescription)")
            }

        default:
            Log.warn("Action logTime: Unknown service: \(service)")
        }
    }

    // MARK: - Process Helpers

    /// Run a process synchronously. Returns true on success.
    /// Pure function — safe to call from any thread.
    @discardableResult
    private nonisolated static func runProcessSync(
        executable: String,
        arguments: [String],
        currentDirectory: String? = nil,
        label: String
    ) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        if let dir = currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: dir)
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                Log.warn("Action \(label): Exit code \(process.terminationStatus), output: \(output.prefix(200))")
                return false
            }
            return true
        } catch {
            Log.error("Action \(label): Failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Run a process asynchronously on a background queue (does not block the action queue).
    private nonisolated func runProcess(executable: String, arguments: [String], label: String, currentDirectory: String? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            Self.runProcessSync(executable: executable, arguments: arguments, currentDirectory: currentDirectory, label: label)
        }
    }

    // MARK: - File Helpers

    /// Atomically append data to a file using fopen "a" — creates the file if it doesn't exist.
    private static func appendToFile(atPath path: String, data: Data) throws {
        guard let fp = fopen(path, "a") else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "Cannot open file for appending: \(path)"
            ])
        }
        defer { fclose(fp) }
        data.withUnsafeBytes { bytes in
            _ = fwrite(bytes.baseAddress!, 1, bytes.count, fp)
        }
    }
}

// MARK: - Adapter bridging OverlayTabsModel + StatusBarController → NotificationActionDelegate

/// Bridges tab-related actions (via OverlayTabsModel) and menu bar actions (via StatusBarController)
/// into a single NotificationActionDelegate conformance.
@MainActor
final class NotificationActionAdapter: NotificationActionDelegate {
    private weak var overlayModel: OverlayTabsModel?
    private let statusBar: StatusBarController

    init(overlayModel: OverlayTabsModel, statusBar: StatusBarController) {
        self.overlayModel = overlayModel
        self.statusBar = statusBar
    }

    func focusTab(for target: TabTarget) {
        overlayModel?.focusTab(for: target)
    }

    @discardableResult
    func styleTab(for target: TabTarget, preset: String, config: [String: String]) -> UUID? {
        overlayModel?.applyNotificationStyle(for: target, stylePreset: preset, config: config)
    }

    func badgeTab(for target: TabTarget, text: String, color: String) {
        overlayModel?.setBadge(for: target, text: text, color: color)
    }

    func insertSnippet(id: String, for target: TabTarget, autoExecute: Bool) {
        overlayModel?.insertSnippet(id: id, for: target, autoExecute: autoExecute)
    }

    func flashMenuBar(duration: Int, animate: Bool) {
        statusBar.flashAlert(duration: duration, animate: animate)
    }
}
