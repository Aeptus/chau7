import Foundation

// MARK: - Profile Switch Trigger

/// Defines the condition that triggers an automatic profile switch.
public enum ProfileSwitchTrigger: Codable, Equatable, Sendable {
    case directory(path: String)
    case gitRepository(name: String)
    case sshHost(hostname: String)
    case processRunning(name: String)
    case environmentVariable(key: String, value: String)

    public var typeDisplayName: String {
        switch self {
        case .directory: return "Directory"
        case .gitRepository: return "Git Repository"
        case .sshHost: return "SSH Host"
        case .processRunning: return "Process"
        case .environmentVariable: return "Environment Variable"
        }
    }

    public var displaySummary: String {
        switch self {
        case .directory(let path): return "cd \(path)"
        case .gitRepository(let name): return "repo: \(name)"
        case .sshHost(let hostname): return "ssh \(hostname)"
        case .processRunning(let name): return "process: \(name)"
        case .environmentVariable(let key, let value): return "\(key)=\(value)"
        }
    }
}

// MARK: - Profile Switch Rule

public struct ProfileSwitchRule: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var isEnabled: Bool
    public var trigger: ProfileSwitchTrigger
    public var profileName: String
    public var priority: Int

    public init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        trigger: ProfileSwitchTrigger,
        profileName: String,
        priority: Int = 0
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.trigger = trigger
        self.profileName = profileName
        self.priority = priority
    }
}

// MARK: - Rule Matching

extension ProfileSwitchRule {
    public func matches(
        directory: String? = nil,
        gitBranch _: String? = nil,
        sshHost: String? = nil,
        processes: [String]? = nil,
        environment: [String: String]? = nil
    ) -> Bool {
        guard isEnabled else { return false }
        switch trigger {
        case .directory(let pattern):
            guard let directory = directory else { return false }
            return ProfileSwitchRule.matchesGlob(path: directory, pattern: pattern)
        case .gitRepository(let name):
            guard let directory = directory else { return false }
            return ProfileSwitchRule.matchesRepoName(directory: directory, repoName: name)
        case .sshHost(let hostname):
            guard let sshHost = sshHost else { return false }
            return sshHost.lowercased() == hostname.lowercased()
        case .processRunning(let name):
            guard let processes = processes else { return false }
            let lowered = name.lowercased()
            return processes.contains { $0.lowercased() == lowered }
        case .environmentVariable(let key, let value):
            guard let environment = environment else { return false }
            return environment[key] == value
        }
    }

    public static func matchesGlob(path: String, pattern: String) -> Bool {
        let expandedPattern = expandTilde(pattern)
        let expandedPath = expandTilde(path)
        let np = expandedPattern.hasSuffix("/") ? String(expandedPattern.dropLast()) : expandedPattern
        let npath = expandedPath.hasSuffix("/") ? String(expandedPath.dropLast()) : expandedPath
        if np.contains("**") {
            return matchesDoubleStarGlob(path: npath, pattern: np)
        }
        let ps = npath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let pp = np.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard ps.count == pp.count else { return false }
        for (s, p) in zip(ps, pp) {
            if p == "*" { continue }
            if !matchesSimpleWildcard(string: s, pattern: p) { return false }
        }
        return true
    }

    private static func matchesDoubleStarGlob(path: String, pattern: String) -> Bool {
        let ps = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let pp = pattern.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return matchSegments(pathSegments: ps, patternSegments: pp, pathIdx: 0, patternIdx: 0)
    }

    private static func matchSegments(
        pathSegments: [String], patternSegments: [String], pathIdx: Int, patternIdx: Int
    ) -> Bool {
        if patternIdx >= patternSegments.count && pathIdx >= pathSegments.count { return true }
        if patternIdx >= patternSegments.count { return false }
        let pat = patternSegments[patternIdx]
        if pat == "**" {
            if matchSegments(
                pathSegments: pathSegments,
                patternSegments: patternSegments,
                pathIdx: pathIdx,
                patternIdx: patternIdx + 1
            ) { return true }
            if pathIdx < pathSegments.count {
                return matchSegments(
                    pathSegments: pathSegments,
                    patternSegments: patternSegments,
                    pathIdx: pathIdx + 1,
                    patternIdx: patternIdx
                )
            }
            return false
        }
        if pathIdx >= pathSegments.count { return false }
        if pat == "*" || matchesSimpleWildcard(string: pathSegments[pathIdx], pattern: pat) {
            return matchSegments(
                pathSegments: pathSegments,
                patternSegments: patternSegments,
                pathIdx: pathIdx + 1,
                patternIdx: patternIdx + 1
            )
        }
        return false
    }

    private static func matchesSimpleWildcard(string: String, pattern: String) -> Bool {
        if pattern == "*" { return true }
        if !pattern.contains("*") { return string == pattern }
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        var remaining = string[...]
        if let first = parts.first, !first.isEmpty {
            guard remaining.hasPrefix(first) else { return false }
            remaining = remaining.dropFirst(first.count)
        }
        if let last = parts.last, !last.isEmpty {
            guard remaining.hasSuffix(last) else { return false }
            remaining = remaining.dropLast(last.count)
        }
        for part in parts.dropFirst().dropLast() where !part.isEmpty {
            guard let range = remaining.range(of: part) else { return false }
            remaining = remaining[range.upperBound...]
        }
        return true
    }

    private static func expandTilde(_ path: String) -> String {
        RuntimeIsolation.expandTilde(in: path)
    }

    private static func matchesRepoName(directory: String, repoName: String) -> Bool {
        (directory as NSString).lastPathComponent.lowercased() == repoName.lowercased()
    }
}

// MARK: - Rule Sorting

public extension [ProfileSwitchRule] {
    func sortedByPriority() -> [ProfileSwitchRule] {
        sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            return lhs.name < rhs.name
        }
    }
}
