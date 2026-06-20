import Foundation
import AppKit
import Chau7Core

// MARK: - copyToClipboard

@MainActor
struct CopyToClipboardActionHandler: NotificationActionHandler {
    let supportedActionTypes: [NotificationActionType] = [.copyToClipboard]

    func execute(payload: ActionPayload, environment _: ActionEnvironment) -> NotificationActionExecutor.ExecutionReport {
        let content = payload.interpolate(payload.configValue("content"))

        DispatchQueue.main.async {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(content, forType: .string)
            Log.info("Action copyToClipboard: Copied \(content.count) characters")
        }
        return .success(.copyToClipboard)
    }
}

// MARK: - writeToFile

@MainActor
struct WriteToFileActionHandler: NotificationActionHandler {
    let supportedActionTypes: [NotificationActionType] = [.writeToFile]

    func execute(payload: ActionPayload, environment _: ActionEnvironment) -> NotificationActionExecutor.ExecutionReport {
        guard let filePath = payload.configValue("filePath"), !filePath.isEmpty else {
            Log.warn("Action writeToFile: No file path specified")
            return .failure("writeToFile missing filePath")
        }

        let format = payload.configValue("format") ?? "text"
        let template = payload.configValue("template")
        let expandedPath = RuntimeIsolation.expandTilde(in: filePath)

        let line: String
        switch format {
        case "json":
            if let data = try? JSONSerialization.data(withJSONObject: payload.eventJSON()),
               let json = String(data: data, encoding: .utf8) {
                line = json
            } else {
                line = "{}"
            }
        case "csv":
            let fields = [payload.event.ts, payload.event.source.rawValue, payload.event.type, payload.event.tool, payload.event.message]
                .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            line = fields.joined(separator: ",")
        default:
            if let tmpl = template, !tmpl.isEmpty {
                line = payload.interpolate(tmpl)
            } else {
                line = "[\(payload.event.ts)] \(payload.event.type): \(payload.event.message)"
            }
        }

        do {
            let fileURL = URL(fileURLWithPath: expandedPath)
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            // Atomic open-or-create+append via fopen "a" — no TOCTOU race
            guard let lineData = (line + "\n").data(using: .utf8) else {
                return .failure("writeToFile failed to encode UTF-8 line")
            }
            try appendToFile(atPath: expandedPath, data: lineData)

            Log.info("Action writeToFile: Appended to \(filePath)")
        } catch {
            Log.error("Action writeToFile: Failed: \(error.localizedDescription)")
            return .failure("writeToFile failed: \(error.localizedDescription)")
        }
        return .success(.writeToFile)
    }
}

// MARK: - openURL

@MainActor
struct OpenURLActionHandler: NotificationActionHandler {
    let supportedActionTypes: [NotificationActionType] = [.openURL]

    func execute(payload: ActionPayload, environment _: ActionEnvironment) -> NotificationActionExecutor.ExecutionReport {
        guard let urlTemplate = payload.configValue("url"), !urlTemplate.isEmpty else {
            Log.warn("Action openURL: No URL specified")
            return .failure("openURL missing url")
        }

        let urlString = payload.interpolate(urlTemplate)
        guard let url = URL(string: urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? urlString) else {
            Log.warn("Action openURL: Invalid URL: \(urlString)")
            return .failure("openURL invalid URL: \(urlString)")
        }

        let browser = payload.configValue("browser") ?? "default"

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
        return .success(.openURL)
    }
}

// MARK: - gitCommit

@MainActor
struct GitCommitActionHandler: NotificationActionHandler {
    let supportedActionTypes: [NotificationActionType] = [.gitCommit]

    func execute(payload: ActionPayload, environment _: ActionEnvironment) -> NotificationActionExecutor.ExecutionReport {
        let message = payload.interpolate(payload.configValue("message") ?? "Auto-commit: ${type}")
        let addAll = payload.configBool("addAll", default: true)
        let push = payload.configBool("push", default: false)
        let repoPath = payload.configValue("repoPath")
        let gitPath = "/usr/bin/git"

        let workingDir: String?
        if let path = repoPath, !path.isEmpty {
            workingDir = RuntimeIsolation.expandTilde(in: path)
        } else {
            workingDir = nil
        }

        DispatchQueue.global(qos: .userInitiated).async {
            if addAll {
                guard runProcessSync(
                    executable: gitPath,
                    arguments: ["add", "-A"],
                    currentDirectory: workingDir,
                    label: "gitCommit(add)"
                ) else { return }
            }

            guard runProcessSync(
                executable: gitPath,
                arguments: ["commit", "-m", message],
                currentDirectory: workingDir,
                label: "gitCommit(commit)"
            ) else { return }

            if push {
                guard runProcessSync(
                    executable: gitPath,
                    arguments: ["push"],
                    currentDirectory: workingDir,
                    label: "gitCommit(push)"
                ) else { return }
            }

            Log.info("Action gitCommit: Completed successfully")
        }
        return .success(.gitCommit)
    }
}
