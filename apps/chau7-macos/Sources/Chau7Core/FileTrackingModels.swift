import Foundation

public enum FileTrackingAction: String, Codable, CaseIterable, Sendable {
    case read
    case created
    case modified
    case deleted
}

public struct FileTouchRecord: Equatable, Codable, Sendable {
    public let turnID: String?
    public let action: FileTrackingAction
    public let timestamp: Date

    public init(turnID: String?, action: FileTrackingAction, timestamp: Date) {
        self.turnID = turnID
        self.action = action
        self.timestamp = timestamp
    }
}

public struct TrackedFileActivity: Equatable, Sendable {
    public let path: String
    public let action: FileTrackingAction

    public init(path: String, action: FileTrackingAction) {
        self.path = path
        self.action = action
    }
}

public enum FileTrackingParser {
    private static let commonExtensionlessFileNames: Set<String> = [
        "Dockerfile", "Containerfile", "Makefile", "Justfile", "Brewfile",
        "Gemfile", "Podfile", "Procfile", "Vagrantfile", "Rakefile",
        "Guardfile", "Fastfile", "Appfile", "Cartfile", "Mintfile",
        "Pipfile", "README", "LICENSE", "NOTICE", "CHANGELOG", "TODO"
    ]

    public static func activities(from event: RuntimeEvent, gitRoot: String? = nil) -> [TrackedFileActivity] {
        guard event.type == RuntimeEventType.toolUse.rawValue else { return [] }
        let toolName = event.data["tool"] ?? ""
        let summary = event.data["args_summary"]
        let primaryFile = event.data["file"]
        return normalize(
            extractActivities(toolName: toolName, summary: summary, primaryFile: primaryFile),
            gitRoot: gitRoot
        )
    }

    public static func activities(from commandBlock: CommandBlock, gitRoot: String? = nil) -> [TrackedFileActivity] {
        guard !commandBlock.changedFiles.isEmpty else { return [] }
        let action = fallbackAction(forCommand: commandBlock.command)
        let unique = Array(Set(commandBlock.changedFiles)).sorted()
        return normalize(unique.map { TrackedFileActivity(path: $0, action: action) }, gitRoot: gitRoot)
    }

    public static func fallbackAction(forCommand command: String) -> FileTrackingAction {
        let tokens = CommandDetection.tokenize(command)
        guard let executable = tokens.first?.lowercased() else { return .modified }
        switch executable {
        case "rm", "unlink":
            return .deleted
        case "touch":
            return .created
        default:
            return .modified
        }
    }

    private static func extractActivities(toolName: String, summary: String?, primaryFile: String?) -> [TrackedFileActivity] {
        switch toolName {
        case "Read":
            return single(primaryFile, action: .read)
        case "Write":
            return single(primaryFile, action: .created)
        case "Edit", "NotebookEdit":
            return single(primaryFile, action: .modified)
        case "Grep", "Glob", "LS":
            return extractTargetActivities(from: summary, fallback: primaryFile, action: .read)
        case "Bash":
            return extractBashActivities(from: summary, fallback: primaryFile)
        default:
            return single(primaryFile, action: .modified)
        }
    }

    private static func extractTargetActivities(from summary: String?, fallback: String?, action: FileTrackingAction) -> [TrackedFileActivity] {
        guard let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return single(fallback, action: action)
        }
        let tokens = CommandDetection.tokenize(summary)
        let candidates = candidatePathTokens(from: tokens)
        if candidates.isEmpty {
            return single(fallback, action: action)
        }
        return dedupe(candidates.map { TrackedFileActivity(path: $0, action: action) })
    }

    private static func extractBashActivities(from summary: String?, fallback: String?) -> [TrackedFileActivity] {
        guard let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return single(fallback, action: .modified)
        }

        let tokens = CommandDetection.tokenize(summary)
        guard let executable = tokens.first?.lowercased() else {
            return single(fallback, action: .modified)
        }

        var activities: [TrackedFileActivity] = []
        let fileTokens = candidatePathTokens(from: nonRedirectArgumentTokens(Array(tokens.dropFirst())))

        switch executable {
        case "cat", "head", "tail", "less", "more", "grep", "rg", "ls", "find", "stat", "file":
            activities.append(contentsOf: fileTokens.map { TrackedFileActivity(path: $0, action: .read) })
        case "sed":
            if tokens.contains("-i") || tokens.contains("--in-place") {
                activities.append(contentsOf: fileTokens.map { TrackedFileActivity(path: $0, action: .modified) })
            } else {
                activities.append(contentsOf: fileTokens.map { TrackedFileActivity(path: $0, action: .read) })
            }
        case "cp":
            if !fileTokens.isEmpty {
                let sourceTokens = Array(fileTokens.dropLast())
                let destination = fileTokens.last
                activities.append(contentsOf: sourceTokens.map { TrackedFileActivity(path: $0, action: .read) })
                if let destination {
                    activities.append(TrackedFileActivity(path: destination, action: .modified))
                }
            }
        case "mv", "rename":
            if fileTokens.count >= 2 {
                activities.append(TrackedFileActivity(path: fileTokens[0], action: .deleted))
                activities.append(TrackedFileActivity(path: fileTokens[1], action: .created))
            }
        case "rm", "unlink":
            activities.append(contentsOf: fileTokens.map { TrackedFileActivity(path: $0, action: .deleted) })
        case "touch":
            activities.append(contentsOf: fileTokens.map { TrackedFileActivity(path: $0, action: .created) })
        case "tee":
            activities.append(contentsOf: fileTokens.map { TrackedFileActivity(path: $0, action: .modified) })
        default:
            if activities.isEmpty {
                activities.append(contentsOf: single(fallback, action: .modified))
            }
        }

        activities.append(contentsOf: extractRedirectActivities(from: tokens))

        if activities.isEmpty {
            activities.append(contentsOf: single(fallback, action: .modified))
        }
        return dedupe(activities)
    }

    private static func extractRedirectActivities(from tokens: [String]) -> [TrackedFileActivity] {
        var activities: [TrackedFileActivity] = []
        for (index, token) in tokens.enumerated() {
            guard isRedirectToken(token) else { continue }
            let target: String?
            if redirectTargetIsEmbedded(token) {
                target = embeddedRedirectTarget(from: token)
            } else {
                target = tokens.indices.contains(index + 1) ? tokens[index + 1] : nil
            }
            guard let target,
                  target != "/dev/null",
                  !target.hasPrefix("&"),
                  looksLikePath(target) else {
                continue
            }
            activities.append(TrackedFileActivity(path: target, action: .modified))
        }
        return activities
    }

    private static func nonRedirectArgumentTokens(_ tokens: [String]) -> [String] {
        var result: [String] = []
        var skipNext = false
        for token in tokens {
            if skipNext {
                skipNext = false
                continue
            }
            if isRedirectToken(token) {
                if !redirectTargetIsEmbedded(token) {
                    skipNext = true
                }
                continue
            }
            result.append(token)
        }
        return result
    }

    private static func isRedirectToken(_ token: String) -> Bool {
        [">", ">>", "1>", "2>", "&>", "1>>", "2>>"].contains(token) || token.contains(">")
    }

    private static func redirectTargetIsEmbedded(_ token: String) -> Bool {
        token != ">" && token != ">>" && token != "1>" && token != "2>" && token != "&>" && token != "1>>" && token != "2>>"
    }

    private static func embeddedRedirectTarget(from token: String) -> String? {
        let patterns = [">>", "1>>", "2>>", "1>", "2>", "&>", ">"]
        for pattern in patterns {
            if token.hasPrefix(pattern) {
                let suffix = String(token.dropFirst(pattern.count))
                return suffix.isEmpty ? nil : suffix
            }
        }
        return nil
    }

    private static func candidatePathTokens(from tokens: [String]) -> [String] {
        tokens.filter { token in
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            guard !trimmed.hasPrefix("-") else { return false }
            guard trimmed != "|", trimmed != "&&", trimmed != "||" else { return false }
            guard !trimmed.contains("=") else { return false }
            return looksLikePath(trimmed)
        }
    }

    private static func looksLikePath(_ token: String) -> Bool {
        if token.hasPrefix("/") || token.hasPrefix("./") || token.hasPrefix("../") || token.hasPrefix("~/") {
            return true
        }
        if commonExtensionlessFileNames.contains(token) {
            return true
        }
        if token.contains("/") || token.contains("*") || token.contains("?") {
            return true
        }
        if token.contains("."),
           token.range(of: #"^[A-Za-z0-9._-]+\.[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private static func normalize(_ activities: [TrackedFileActivity], gitRoot: String?) -> [TrackedFileActivity] {
        dedupe(activities.compactMap { activity in
            guard let path = normalizePath(activity.path, gitRoot: gitRoot) else { return nil }
            return TrackedFileActivity(path: path, action: activity.action)
        })
    }

    private static func normalizePath(_ path: String, gitRoot: String?) -> String? {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t\r\n"))
        guard !trimmed.isEmpty else { return nil }
        let expanded: String
        if trimmed.hasPrefix("~/") {
            expanded = NSString(string: trimmed).expandingTildeInPath
        } else {
            expanded = trimmed
        }

        guard let gitRoot, !gitRoot.isEmpty else { return expanded }
        let rootWithSlash = gitRoot.hasSuffix("/") ? gitRoot : gitRoot + "/"
        if expanded.hasPrefix(rootWithSlash) {
            return String(expanded.dropFirst(rootWithSlash.count))
        }
        return expanded
    }

    private static func single(_ path: String?, action: FileTrackingAction) -> [TrackedFileActivity] {
        guard let path, !path.isEmpty else { return [] }
        return [TrackedFileActivity(path: path, action: action)]
    }

    private static func dedupe(_ activities: [TrackedFileActivity]) -> [TrackedFileActivity] {
        var seen: Set<String> = []
        var result: [TrackedFileActivity] = []
        for activity in activities {
            let key = "\(activity.action.rawValue)|\(activity.path)"
            guard seen.insert(key).inserted else { continue }
            result.append(activity)
        }
        return result
    }
}

public final class FleetFileIndex: @unchecked Sendable {
    private let lock = NSLock()
    public private(set) var agentsByFile: [String: Set<String>] = [:]
    private var filesByAgent: [String: Set<String>] = [:]

    public init() {}

    public func publish(agentID: String, files: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        removeLocked(agentID: agentID)
        filesByAgent[agentID] = files
        for file in files {
            agentsByFile[file, default: []].insert(agentID)
        }
    }

    public func remove(agentID: String) {
        lock.lock()
        defer { lock.unlock() }
        removeLocked(agentID: agentID)
    }

    public func reset() {
        lock.lock()
        agentsByFile.removeAll()
        filesByAgent.removeAll()
        lock.unlock()
    }

    public func overlappingFiles(minAgents: Int = 2) -> [String: Set<String>] {
        lock.lock()
        defer { lock.unlock() }
        return agentsByFile.filter { $0.value.count >= minAgents }
    }

    private func removeLocked(agentID: String) {
        guard let existing = filesByAgent.removeValue(forKey: agentID) else { return }
        for file in existing {
            guard var agents = agentsByFile[file] else { continue }
            agents.remove(agentID)
            if agents.isEmpty {
                agentsByFile.removeValue(forKey: file)
            } else {
                agentsByFile[file] = agents
            }
        }
    }
}
