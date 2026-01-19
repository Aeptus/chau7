import Foundation
import AppKit
import UserNotifications
import Chau7Core

/// Executes notification actions in response to events
final class NotificationActionExecutor {
    static let shared = NotificationActionExecutor()

    // MARK: - Dependencies (injected from app)
    var tabFocusHandler: ((String) -> Void)?
    var tabBadgeHandler: ((String, String, String) -> Void)?  // tabId, text, color
    var snippetExecuteHandler: ((String, String, Bool) -> Void)?  // tabId, snippetId, autoExecute
    var menuBarAlertHandler: ((Int, Bool) -> Void)?  // duration, animate

    // MARK: - Time Tracking State
    private var activeTimers: [String: Date] = [:]
    private let queue = DispatchQueue(label: "com.chau7.actionExecutor", qos: .userInitiated)

    private init() {}

    // MARK: - Main Entry Point

    func execute(actions: [NotificationActionConfig], for event: AIEvent) {
        for actionConfig in actions where actionConfig.enabled {
            queue.async { [weak self] in
                self?.executeAction(actionConfig, for: event)
            }
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
        case .badgeTab:
            executeBadgeTab(context)

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
        let title = ctx.interpolate(ctx.configValue("customTitle"))
        let body = ctx.interpolate(ctx.configValue("customBody"))

        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? ctx.event.notificationTitle(toolOverride: nil) : title
        content.body = body.isEmpty ? ctx.event.notificationBody : body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                Log.error("Action showNotification failed: \(error.localizedDescription)")
            }
        }
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

            if focusTab, let handler = self?.tabFocusHandler {
                handler(ctx.event.tool)
            }
        }
    }

    private func executeBadgeTab(_ ctx: ActionContext) {
        let badgeText = ctx.configValue("badgeText") ?? "!"
        let badgeColor = ctx.configValue("badgeColor") ?? "red"

        DispatchQueue.main.async { [weak self] in
            self?.tabBadgeHandler?(ctx.event.tool, badgeText, badgeColor)
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
        process.arguments = ["-c", ctx.interpolate(script)]
        process.environment = ProcessInfo.processInfo.environment.merging(ctx.environmentVariables()) { _, new in new }

        if let dir = workingDir, !dir.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
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

            process.waitUntilExit()

            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if process.terminationStatus != 0 {
                Log.warn("Action runScript: Exit code \(process.terminationStatus), output: \(output.prefix(500))")
            } else {
                Log.info("Action runScript: Completed successfully")
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

        var script = "shortcuts run \"\(shortcutName)\""
        if passEventData {
            if let jsonData = try? JSONSerialization.data(withJSONObject: ctx.eventJSON()),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                let escaped = jsonString.replacingOccurrences(of: "'", with: "'\\''")
                script += " <<< '\(escaped)'"
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", script]

        do {
            try process.run()
            process.waitUntilExit()
            Log.info("Action runShortcut: Executed '\(shortcutName)'")
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
            self?.snippetExecuteHandler?(ctx.event.tool, snippetId, autoExecute)
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
                if httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 {
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

        URLSession.shared.dataTask(with: request) { _, response, error in
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

        URLSession.shared.dataTask(with: request) { _, response, error in
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

        let command: String
        switch operation {
        case "restart":
            command = "\(dockerPath) restart \(container)"
        case "stop":
            command = "\(dockerPath) stop \(container)"
        case "start":
            command = "\(dockerPath) start \(container)"
        case "rebuild":
            command = "\(dockerPath) stop \(container) && \(dockerPath) rm \(container) && \(dockerPath) build -t \(container) . && \(dockerPath) run -d --name \(container) \(container)"
        default:
            Log.warn("Action dockerBump: Unknown operation: \(operation)")
            return
        }

        runShellCommand(command, label: "dockerBump")
    }

    private func executeDockerCompose(_ ctx: ActionContext) {
        guard let composePath = ctx.configValue("composePath"), !composePath.isEmpty else {
            Log.warn("Action dockerCompose: No compose file path specified")
            return
        }

        let operation = ctx.configValue("operation") ?? "restart"
        let services = ctx.configValue("services") ?? ""

        let expandedPath = (composePath as NSString).expandingTildeInPath
        let servicesArg = services.isEmpty ? "" : " \(services)"

        let command: String
        switch operation {
        case "up":
            command = "docker-compose -f '\(expandedPath)' up -d\(servicesArg)"
        case "down":
            command = "docker-compose -f '\(expandedPath)' down\(servicesArg)"
        case "restart":
            command = "docker-compose -f '\(expandedPath)' restart\(servicesArg)"
        case "build":
            command = "docker-compose -f '\(expandedPath)' build\(servicesArg)"
        case "pull":
            command = "docker-compose -f '\(expandedPath)' pull\(servicesArg)"
        default:
            Log.warn("Action dockerCompose: Unknown operation: \(operation)")
            return
        }

        runShellCommand(command, label: "dockerCompose")
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

        var contextArg = ""
        if let ctx = kubectlContext, !ctx.isEmpty {
            contextArg = " --context=\(ctx)"
        }

        let command: String
        switch operation {
        case "restart":
            command = "kubectl\(contextArg) -n \(namespace) rollout restart deployment/\(deployment)"
        case "scale":
            let replicaCount = replicas ?? "1"
            command = "kubectl\(contextArg) -n \(namespace) scale deployment/\(deployment) --replicas=\(replicaCount)"
        case "status":
            command = "kubectl\(contextArg) -n \(namespace) rollout status deployment/\(deployment)"
        default:
            Log.warn("Action kubernetesRollout: Unknown operation: \(operation)")
            return
        }

        runShellCommand(command, label: "kubernetesRollout")
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
        let expandedPath = (filePath as NSString).expandingTildeInPath

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

            if FileManager.default.fileExists(atPath: expandedPath) {
                let handle = try FileHandle(forWritingTo: fileURL)
                handle.seekToEndOfFile()
                handle.write((line + "\n").data(using: .utf8)!)
                handle.closeFile()
            } else {
                try (line + "\n").write(toFile: expandedPath, atomically: true, encoding: .utf8)
            }

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

        var commands: [String] = []
        if addAll {
            commands.append("git add -A")
        }
        commands.append("git commit -m '\(message.replacingOccurrences(of: "'", with: "'\\''"))'")
        if push {
            commands.append("git push")
        }

        let command = commands.joined(separator: " && ")

        if let path = repoPath, !path.isEmpty {
            let expandedPath = (path as NSString).expandingTildeInPath
            runShellCommand("cd '\(expandedPath)' && \(command)", label: "gitCommit")
        } else {
            runShellCommand(command, label: "gitCommit")
        }
    }

    // MARK: - Accessibility Actions

    private func executeVoiceAnnounce(_ ctx: ActionContext) {
        let text = ctx.interpolate(ctx.configValue("text"))
        let voice = ctx.configValue("voice") ?? "default"
        let rate = ctx.configInt("rate", default: 175)

        DispatchQueue.main.async {
            let synthesizer = NSSpeechSynthesizer()

            if voice != "default" {
                synthesizer.setVoice(NSSpeechSynthesizer.VoiceName(rawValue: "com.apple.speech.synthesis.voice.\(voice.lowercased())"))
            }

            synthesizer.rate = Float(rate)
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

        DispatchQueue.main.async {
            guard let screen = NSScreen.main else { return }

            let flashWindow = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            flashWindow.level = .screenSaver
            flashWindow.backgroundColor = color
            flashWindow.ignoresMouseEvents = true
            flashWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            func flash(remaining: Int) {
                guard remaining > 0 else {
                    flashWindow.orderOut(nil)
                    return
                }

                flashWindow.alphaValue = 0.5
                flashWindow.orderFront(nil)

                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(duration)) {
                    flashWindow.alphaValue = 0
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) {
                        flash(remaining: remaining - 1)
                    }
                }
            }

            flash(remaining: count)
            Log.info("Action flashScreen: Flashing \(count) times")
        }
    }

    private func executeMenuBarAlert(_ ctx: ActionContext) {
        let duration = ctx.configInt("duration", default: 5)
        let animate = ctx.configBool("animate", default: true)

        DispatchQueue.main.async { [weak self] in
            self?.menuBarAlertHandler?(duration, animate)
            Log.info("Action menuBarAlert: Alert for \(duration) seconds")
        }
    }

    // MARK: - Time Tracking Actions

    private func executeStartTimer(_ ctx: ActionContext) {
        let timerName = ctx.interpolate(ctx.configValue("timerName") ?? ctx.event.tool)
        let project = ctx.configValue("project") ?? ""

        queue.sync {
            activeTimers[timerName] = Date()
        }

        Log.info("Action startTimer: Started '\(timerName)' for project '\(project)'")
    }

    private func executeStopTimer(_ ctx: ActionContext) {
        let timerName = ctx.configValue("timerName")

        var stoppedTimer: (name: String, start: Date)?

        queue.sync {
            if let name = timerName, !name.isEmpty {
                if let start = activeTimers.removeValue(forKey: name) {
                    stoppedTimer = (name, start)
                }
            } else if let (name, start) = activeTimers.first {
                activeTimers.removeValue(forKey: name)
                stoppedTimer = (name, start)
            }
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
            let expandedPath = (filePath as NSString).expandingTildeInPath
            let entry = "\(ctx.event.ts),\"\(description.replacingOccurrences(of: "\"", with: "\"\""))\""

            do {
                let fileURL = URL(fileURLWithPath: expandedPath)
                if FileManager.default.fileExists(atPath: expandedPath) {
                    let handle = try FileHandle(forWritingTo: fileURL)
                    handle.seekToEndOfFile()
                    handle.write((entry + "\n").data(using: .utf8)!)
                    handle.closeFile()
                } else {
                    try "timestamp,description\n\(entry)\n".write(toFile: expandedPath, atomically: true, encoding: .utf8)
                }
                Log.info("Action logTime: Logged to \(filePath)")
            } catch {
                Log.error("Action logTime: Failed to write file: \(error.localizedDescription)")
            }

        case "toggl", "clockify":
            guard let apiKey = ctx.configValue("apiKey"), !apiKey.isEmpty else {
                Log.warn("Action logTime: API key required for \(service)")
                return
            }
            // TODO: Implement Toggl/Clockify API integration
            Log.warn("Action logTime: \(service) integration not yet implemented")

        default:
            Log.warn("Action logTime: Unknown service: \(service)")
        }
    }

    // MARK: - Helpers

    private func runShellCommand(_ command: String, label: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                Log.warn("Action \(label): Exit code \(process.terminationStatus), output: \(output.prefix(200))")
            } else {
                Log.info("Action \(label): Completed successfully")
            }
        } catch {
            Log.error("Action \(label): Failed: \(error.localizedDescription)")
        }
    }
}
