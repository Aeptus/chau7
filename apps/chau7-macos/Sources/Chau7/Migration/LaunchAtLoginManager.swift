import Foundation
import Chau7Core

enum LaunchAtLoginManager {
    private static let label = Bundle.main.bundleIdentifier ?? "com.chau7"

    private static func agentURL(environment: [String: String]) -> URL {
        RuntimeIsolation.homeDirectory(environment: environment)
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent("\(label).plist")
    }

    static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard !RuntimeIsolation.isIsolatedTestMode(environment: environment) else { return false }
        return FileManager.default.fileExists(atPath: agentURL(environment: environment).path)
    }

    static func setEnabled(
        _ enabled: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard !RuntimeIsolation.isIsolatedTestMode(environment: environment) else {
            Log.info("LaunchAtLogin: ignored in isolated test mode.")
            return
        }
        if enabled {
            install(environment: environment)
        } else {
            uninstall(environment: environment)
        }
    }

    private static func install(environment: [String: String]) {
        guard let executablePath = Bundle.main.executableURL?.path else {
            Log.error("LaunchAtLogin: missing executable path.")
            return
        }

        let agentURL = agentURL(environment: environment)
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

        Log.info("LaunchAtLogin: enabled for next login.")
    }

    private static func uninstall(environment: [String: String]) {
        let agentURL = agentURL(environment: environment)
        if FileManager.default.fileExists(atPath: agentURL.path) {
            do {
                try FileManager.default.removeItem(at: agentURL)
            } catch {
                Log.warn("LaunchAtLogin: failed to remove plist: \(error.localizedDescription)")
            }
        }
        Log.info("LaunchAtLogin: disabled.")
    }
}
