#if os(macOS)
import Foundation

/// Live resolution of "which AI tool is currently running in this shell" from the OS process tree.
///
/// Chau7's tab identity has historically been driven by persisted metadata written during
/// detection. That coupling causes tabs restored with stale provider to stay locked, because
/// no downstream signal can correct the persisted state without re-introducing "output pattern
/// hijack" holes. This resolver is the ground truth: walk the descendants of a session's
/// shell PID, look for an executable basename that maps to a known AI tool via
/// `AIToolRegistry.commandNameMap`, and return its display name.
///
/// Wrapped scripts (Node, Python, npx shims) are acknowledged limitations — the resolver
/// skips them because their `comm` is the interpreter, not the tool. Command-line detection
/// and output pattern matching continue to cover those cases.
public enum ProcessTreeProviderResolver {

    /// Structured adjacency + basename map from a single `ps` invocation.
    /// Callers that resolve many shells per tick share one snapshot to amortize the shell-out.
    public struct Snapshot: Sendable {
        public let childrenOf: [pid_t: [pid_t]]
        public let commOf: [pid_t: String]

        public init(childrenOf: [pid_t: [pid_t]], commOf: [pid_t: String]) {
            self.childrenOf = childrenOf
            self.commOf = commOf
        }
    }

    /// Basenames skipped during matching — shells, multiplexers, jump-hosts, and common
    /// script interpreters. A tool whose foreground `comm` is `node` will be missed; that
    /// is a known limitation documented above.
    static let skippedBasenames = Set<String>([
        "zsh", "bash", "fish", "sh", "dash", "ksh",
        "tmux", "tmux-server", "screen",
        "ssh", "sudo", "su", "login", "env",
        "node", "python", "python3", "ruby", "npx",
        "ps"
    ])

    /// Shells out to `ps -axo pid,ppid,comm` and parses it into a `Snapshot`. Returns nil
    /// if the subprocess fails; callers should treat nil as "no live signal available".
    public static func captureSnapshot(runner: (String, [String]) -> String? = defaultRunner) -> Snapshot? {
        guard let output = runner("/bin/ps", ["-axo", "pid,ppid,comm"]) else {
            return nil
        }
        return parse(psOutput: output)
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
            if let comm = snapshot.commOf[pid] {
                let base = basename(of: comm).lowercased()
                if !skippedBasenames.contains(base),
                   let match = AIToolRegistry.commandNameMap[base] {
                    if let current = bestMatch {
                        if depth > current.depth {
                            bestMatch = (depth, match)
                        }
                    } else {
                        bestMatch = (depth, match)
                    }
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

    private static func basename(of path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
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
