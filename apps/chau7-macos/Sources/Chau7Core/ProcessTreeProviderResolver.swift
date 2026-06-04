#if os(macOS)
import Foundation

/// Live resolution of "which AI tool is currently running in this shell" from the OS process tree.
///
/// Chau7's tab identity has historically been driven by persisted metadata written during
/// detection. That coupling causes tabs restored with stale provider to stay locked, because
/// no downstream signal can correct the persisted state without re-introducing "output pattern
/// hijack" holes. This resolver is the ground truth: walk the descendants of a session's
/// shell PID, look for an executable basename or argv script/package token that maps to a
/// known AI tool via `AIToolRegistry.commandNameMap`, and return its display name.
public enum ProcessTreeProviderResolver {

    /// Structured adjacency + process identity maps from shared `ps` snapshots.
    /// Callers that resolve many shells per tick share one snapshot to amortize the shell-out.
    public struct Snapshot: Sendable {
        public let childrenOf: [pid_t: [pid_t]]
        public let commOf: [pid_t: String]
        public let argsOf: [pid_t: String]

        public init(childrenOf: [pid_t: [pid_t]], commOf: [pid_t: String], argsOf: [pid_t: String] = [:]) {
            self.childrenOf = childrenOf
            self.commOf = commOf
            self.argsOf = argsOf
        }
    }

    /// Basenames skipped during matching — shells, multiplexers, jump-hosts, and common
    /// script interpreters. Interpreter processes are still inspected through argv, because
    /// npm/Volta-installed CLIs commonly show `node` in `comm` and the real tool in args.
    static let skippedBasenames = Set<String>([
        "zsh", "bash", "fish", "sh", "dash", "ksh",
        "tmux", "tmux-server", "screen",
        "ssh", "sudo", "su", "login", "env",
        "node", "python", "python3", "ruby", "npx",
        "ps"
    ])

    /// Shells out to `ps -axo pid,ppid,comm` plus `ps -axo pid,ppid,args` and parses them
    /// into a `Snapshot`. Returns nil
    /// if the subprocess fails; callers should treat nil as "no live signal available".
    public static func captureSnapshot(runner: (String, [String]) -> String? = defaultRunner) -> Snapshot? {
        guard let commOutput = runner("/bin/ps", ["-axo", "pid,ppid,comm"]) else {
            return nil
        }
        let commSnapshot = parse(psOutput: commOutput)
        guard let argsOutput = runner("/bin/ps", ["-axo", "pid,ppid,args"]) else {
            return commSnapshot
        }
        return Snapshot(
            childrenOf: commSnapshot.childrenOf,
            commOf: commSnapshot.commOf,
            argsOf: parseArgs(psOutput: argsOutput)
        )
    }

    /// Walks descendants of `shellPid` (BFS) and returns the deepest match against
    /// `AIToolRegistry.commandNameMap`. If `snapshot` is nil, captures one internally.
    public static func resolve(shellPid: pid_t, snapshot: Snapshot? = nil) -> String? {
        guard shellPid > 0 else { return nil }
        guard let snapshot = snapshot ?? captureSnapshot() else { return nil }

        var bestMatch: (depth: Int, name: String)?
        var queue: [(pid: pid_t, depth: Int)] = (snapshot.childrenOf[shellPid] ?? [])
            .map { ($0, 1) }

        while !queue.isEmpty {
            let (pid, depth) = queue.removeFirst()
            if let match = matchProcess(comm: snapshot.commOf[pid], args: snapshot.argsOf[pid]) {
                if let current = bestMatch {
                    if depth > current.depth {
                        bestMatch = (depth, match)
                    }
                } else {
                    bestMatch = (depth, match)
                }
            }
            if let grandchildren = snapshot.childrenOf[pid] {
                queue.append(contentsOf: grandchildren.map { ($0, depth + 1) })
            }
        }

        return bestMatch?.name
    }

    // MARK: - Parsing

    static func parse(psOutput: String) -> Snapshot {
        var childrenOf: [pid_t: [pid_t]] = [:]
        var commOf: [pid_t: String] = [:]

        for line in psOutput.split(separator: "\n") {
            let cols = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard cols.count >= 3,
                  let pid = Int32(cols[0].trimmingCharacters(in: .whitespaces)),
                  let ppid = Int32(cols[1].trimmingCharacters(in: .whitespaces)) else {
                continue
            }
            let comm = String(cols[2]).trimmingCharacters(in: .whitespaces)
            commOf[pid] = comm
            childrenOf[ppid, default: []].append(pid)
        }

        return Snapshot(childrenOf: childrenOf, commOf: commOf)
    }

    static func parseArgs(psOutput: String) -> [pid_t: String] {
        var argsOf: [pid_t: String] = [:]

        for line in psOutput.split(separator: "\n") {
            let cols = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard cols.count >= 3,
                  let pid = Int32(cols[0].trimmingCharacters(in: .whitespaces)),
                  Int32(cols[1].trimmingCharacters(in: .whitespaces)) != nil else {
                continue
            }
            let args = String(cols[2]).trimmingCharacters(in: .whitespaces)
            if !args.isEmpty {
                argsOf[pid] = args
            }
        }

        return argsOf
    }

    static func matchProcess(comm: String?, args: String?) -> String? {
        if let comm {
            let base = basename(of: comm).lowercased()
            if !skippedBasenames.contains(base),
               let match = AIToolRegistry.commandNameMap[base] {
                return match
            }
        }

        guard let args, !args.isEmpty else { return nil }
        return matchArgvExecutableToken(in: args)
    }

    static func matchArgvExecutableToken(in args: String) -> String? {
        if let direct = CommandDetection.detectApp(from: args) {
            return direct
        }

        let tokens = CommandDetection.tokenize(args)
        guard !tokens.isEmpty else { return nil }

        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            let normalized = CommandDetection.normalizeToken(token)

            if index == 0 {
                if !skippedBasenames.contains(normalized),
                   let match = AIToolRegistry.commandNameMap[normalized] {
                    return match
                }
                index += 1
                continue
            }

            if token == "--" {
                index += 1
                continue
            }

            if token.hasPrefix("-") {
                index += 1
                continue
            }

            guard isExecutableLikeArgument(token) else {
                index += 1
                continue
            }

            if let match = AIToolRegistry.commandNameMap[normalized] {
                return match
            }

            index += 1
        }

        return nil
    }

    private static func basename(of path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    private static func isExecutableLikeArgument(_ token: String) -> Bool {
        token.contains("/")
            || token.hasPrefix(".")
            || token.hasPrefix("~")
            || token.contains("node_modules")
            || token.contains(".bin")
    }

    /// Default subprocess runner. Kept internal so tests can inject deterministic fixtures.
    public static let defaultRunner: (String, [String]) -> String? = { path, args in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
#endif
