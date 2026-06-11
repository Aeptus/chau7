import Foundation
import Chau7Core

// MARK: - runScript

@MainActor
struct RunScriptActionHandler: NotificationActionHandler {
    let supportedActionTypes: [NotificationActionType] = [.runScript]

    func execute(payload: ActionPayload, environment _: ActionEnvironment) -> NotificationActionExecutor.ExecutionReport {
        guard let script = payload.configValue("script"), !script.isEmpty else {
            Log.warn("Action runScript: No script provided")
            var report = NotificationActionExecutor.ExecutionReport()
            report.recordFailure("runScript missing script")
            return report
        }

        let shell = payload.configValue("shell") ?? "/bin/zsh"
        let timeout = payload.configInt("timeout", default: 30)
        let workingDir = payload.configValue("workingDir")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // Pass script directly to shell — do NOT interpolate event data into the script.
        // Event data is available only via environment variables ($CHAU7_MESSAGE, etc.)
        process.arguments = ["-c", script]
        process.environment = ProcessInfo.processInfo.environment.merging(payload.environmentVariables()) { _, new in new }

        if let dir = workingDir, !dir.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: RuntimeIsolation.expandTilde(in: dir))
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()

            // SIGTERM then SIGKILL escalation via ProcessRunner — a script that
            // traps SIGTERM (or is blocked on uninterruptible I/O) would
            // otherwise hang past the user's timeout.
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeout)) {
                guard process.isRunning else { return }
                Log.warn("Action runScript: Timeout after \(timeout)s, terminating")
                ProcessRunner.terminate(process, label: "Action runScript")
            }

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
            var report = NotificationActionExecutor.ExecutionReport()
            report.recordFailure("runScript failed to launch: \(error.localizedDescription)")
            return report
        }
        var report = NotificationActionExecutor.ExecutionReport()
        report.recordSuccess(.runScript)
        return report
    }
}

// MARK: - runShortcut

@MainActor
struct RunShortcutActionHandler: NotificationActionHandler {
    let supportedActionTypes: [NotificationActionType] = [.runShortcut]

    func execute(payload: ActionPayload, environment _: ActionEnvironment) -> NotificationActionExecutor.ExecutionReport {
        guard let shortcutName = payload.configValue("shortcutName"), !shortcutName.isEmpty else {
            Log.warn("Action runShortcut: No shortcut name provided")
            var report = NotificationActionExecutor.ExecutionReport()
            report.recordFailure("runShortcut missing shortcutName")
            return report
        }

        let passEventData = payload.configBool("passEventData", default: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", shortcutName]

        let inputPipe: Pipe?
        if passEventData {
            inputPipe = Pipe()
            process.standardInput = inputPipe
        } else {
            inputPipe = nil
        }

        do {
            try process.run()

            if let inputPipe,
               let jsonData = try? JSONSerialization.data(withJSONObject: payload.eventJSON()) {
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
            var report = NotificationActionExecutor.ExecutionReport()
            report.recordFailure("runShortcut failed to launch: \(error.localizedDescription)")
            return report
        }
        var report = NotificationActionExecutor.ExecutionReport()
        report.recordSuccess(.runShortcut)
        return report
    }
}

// MARK: - executeSnippet

@MainActor
struct ExecuteSnippetActionHandler: NotificationActionHandler {
    let supportedActionTypes: [NotificationActionType] = [.executeSnippet]

    func execute(payload: ActionPayload, environment: ActionEnvironment) -> NotificationActionExecutor.ExecutionReport {
        guard let snippetId = payload.configValue("snippetId"), !snippetId.isEmpty else {
            Log.warn("Action executeSnippet: No snippet ID provided")
            var report = NotificationActionExecutor.ExecutionReport()
            report.recordFailure("executeSnippet missing snippetId")
            return report
        }

        let autoExecute = payload.configBool("autoExecute", default: false)
        var report = NotificationActionExecutor.ExecutionReport()
        guard let tabID = payload.event.tabID else {
            Log.warn("Action executeSnippet: Missing explicit tabID for event \(payload.event.id.uuidString)")
            report.recordFailure("executeSnippet missing explicit tabID")
            return report
        }
        if environment.delegate?.insertSnippet(id: snippetId, tabID: tabID, autoExecute: autoExecute) == true {
            report.recordSuccess(.executeSnippet)
        } else {
            Log.warn("Action executeSnippet: Explicit tabID not found across windows for event \(payload.event.id.uuidString)")
            report.recordFailure("executeSnippet failed for explicit tabID \(tabID.uuidString)")
        }
        return report
    }
}
