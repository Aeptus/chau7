import Foundation
import Darwin

enum LaunchAtLoginManager {
    private static let label = Bundle.main.bundleIdentifier ?? "com.chau7"

    private static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent("\(label).plist")
    }

    static func isEnabled() -> Bool {
        if isJobLoaded() {
            return true
        }
        return FileManager.default.fileExists(atPath: agentURL.path)
    }

    static func setEnabled(_ enabled: Bool) {
        if enabled {
            install()
        } else {
            uninstall()
        }
    }

    private static func install() {
        guard let executablePath = Bundle.main.executableURL?.path else {
            Log.error("LaunchAtLogin: missing executable path.")
            return
        }

        let agentDir = agentURL.deletingLastPathComponent()
        guard FileOperations.createDirectory(at: agentDir) else {
            Log.error("LaunchAtLogin: failed to create \(agentDir.path).")
            return
        }

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "KeepAlive": false
        ]

        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            guard FileOperations.writeData(data, to: agentURL, options: [.atomic]) else { return }
        } catch {
            Log.error("LaunchAtLogin: failed to encode plist: \(error.localizedDescription)")
            return
        }

        let domain = launchDomain
        _ = runLaunchctl(["bootout", domain, agentURL.path], logOutput: false)
        if !runLaunchctl(["bootstrap", domain, agentURL.path]) {
            _ = runLaunchctl(["load", "-w", agentURL.path])
        }
        Log.info("LaunchAtLogin: enabled.")
    }

    private static func uninstall() {
        let domain = launchDomain
        _ = runLaunchctl(["bootout", domain, agentURL.path], logOutput: false)
        _ = runLaunchctl(["unload", "-w", agentURL.path], logOutput: false)

        if FileManager.default.fileExists(atPath: agentURL.path) {
            do {
                try FileManager.default.removeItem(at: agentURL)
            } catch {
                Log.warn("LaunchAtLogin: failed to remove plist: \(error.localizedDescription)")
            }
        }
        Log.info("LaunchAtLogin: disabled.")
    }

    private static var launchDomain: String {
        "gui/\(getuid())"
    }

    private static func isJobLoaded() -> Bool {
        runLaunchctl(["print", "\(launchDomain)/\(label)"], logOutput: false)
    }

    @discardableResult
    private static func runLaunchctl(_ arguments: [String], logOutput: Bool = true) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            if logOutput {
                Log.warn("LaunchAtLogin: launchctl failed: \(error.localizedDescription)")
            }
            return false
        }

        if logOutput, let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8),
           !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Log.trace("LaunchAtLogin: launchctl output: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        return process.terminationStatus == 0
    }
}
