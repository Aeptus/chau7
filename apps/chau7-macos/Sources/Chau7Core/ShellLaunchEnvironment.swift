import Foundation

/// Resolves shell startup environment values for terminal launches.
public enum ShellLaunchEnvironment {
    public static func preferredPATH(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let home = userHome(environment: environment)
        let inherited = pathEntries(environment["PATH"])

        var entries: [String] = []
        if !home.isEmpty {
            entries.append(home + "/bin")
            entries.append(home + "/.local/bin")
            entries.append(home + "/.volta/bin")
            entries.append(home + "/.cargo/bin")
            entries.append(home + "/.bun/bin")
        }

        entries.append(contentsOf: [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin"
        ])
        entries.append(contentsOf: inherited)
        entries.append(contentsOf: [
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ])

        return deduplicated(entries).joined(separator: ":")
    }

    public static func userHome(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let home = normalized(environment["HOME"]) {
            return home
        }
        return RuntimeIsolation.homePath(environment: environment)
    }

    public static func userZdotdir(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        normalized(environment["ZDOTDIR"]) ?? userHome(environment: environment)
    }

    public static func userXDGConfigHome(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let xdg = normalized(environment["XDG_CONFIG_HOME"]) {
            return xdg
        }
        return URL(fileURLWithPath: userHome(environment: environment), isDirectory: true)
            .appendingPathComponent(".config", isDirectory: true)
            .path
    }

    private static func pathEntries(_ raw: String?) -> [String] {
        guard let raw = normalized(raw) else { return [] }
        return raw
            .split(separator: ":")
            .map(String.init)
            .compactMap(normalized)
    }

    private static func deduplicated(_ entries: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for entry in entries {
            guard seen.insert(entry).inserted else { continue }
            result.append(entry)
        }
        return result
    }

    private static func normalized(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
