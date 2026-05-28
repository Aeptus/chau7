import Foundation

/// Resolves shell startup environment values for terminal launches.
public enum ShellLaunchEnvironment {
    public static func utf8LocaleEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fallback: String = "en_US.UTF-8"
    ) -> [String: String] {
        let lang = utf8Locale(environment["LANG"]) ?? fallback
        let ctype = utf8Locale(environment["LC_CTYPE"]) ?? lang

        var result = [
            "LANG": lang,
            "LC_CTYPE": ctype
        ]

        if let inheritedLCAll = normalized(environment["LC_ALL"]) {
            result["LC_ALL"] = inheritedLCAll
        }

        return result
    }

    public static func preferredPATH(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String {
        let home = userHome(environment: environment)
        let inherited = pathEntries(environment["PATH"])

        var entries: [String] = []
        if !home.isEmpty {
            entries.append(home + "/bin")
            entries.append(home + "/.local/bin")
            entries.append(contentsOf: codexVoltaImageBinEntries(home: home, fileManager: fileManager))
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

    private static func codexVoltaImageBinEntries(home: String, fileManager: FileManager) -> [String] {
        let nodeImagesRoot = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".volta", isDirectory: true)
            .appendingPathComponent("tools", isDirectory: true)
            .appendingPathComponent("image", isDirectory: true)
            .appendingPathComponent("node", isDirectory: true)
        guard let nodeImages = try? fileManager.contentsOfDirectory(
            at: nodeImagesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return nodeImages
            .filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
            .map { $0.appendingPathComponent("bin", isDirectory: true).path }
            .filter { binPath in
                fileManager.isExecutableFile(atPath: (binPath as NSString).appendingPathComponent("codex"))
            }
    }

    private static func normalized(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func utf8Locale(_ raw: String?) -> String? {
        guard let value = normalized(raw) else { return nil }
        let lowercased = value.lowercased()
        guard lowercased.contains("utf-8") || lowercased.contains("utf8") else { return nil }
        return value
    }
}
