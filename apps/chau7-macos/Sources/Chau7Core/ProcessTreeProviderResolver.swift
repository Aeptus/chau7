#if os(macOS)
import Darwin
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

    /// Structured adjacency + process identity maps from a single process-table snapshot.
    /// Callers that resolve many shells per tick share one snapshot to amortize enumeration.
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

    /// One process-table entry: pid, parent pid, the command name (`comm`/argv[0]),
    /// and the full argv when it was worth fetching. Native enumeration only fetches
    /// argv for interpreter processes; the `ps` fallback fills it for every row.
    struct ProcessRow: Equatable {
        let pid: pid_t
        let ppid: pid_t
        let command: String
        let argv: String?
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

    /// Interpreter basenames whose real tool lives in argv (e.g. `node …/gemini`).
    /// Native enumeration fetches argv only for these — every other process is matched
    /// by its command name alone, so the common case avoids a per-PID `sysctl`.
    static let argvNeededBasenames = Set<String>([
        "node", "python", "python3", "ruby", "npx"
    ])

    /// Captures the live process tree without spawning a subprocess: it enumerates the
    /// process table via libproc and reads argv (only for interpreters) via `sysctl`.
    /// Falls back to a single `ps -axo pid,ppid,args` scan if native enumeration yields
    /// nothing. Returns nil when both fail; callers treat nil as "no live signal available".
    public static func captureSnapshot() -> Snapshot? {
        captureSnapshot(rowProvider: nativeRows, runner: defaultRunner)
    }

    /// Test seam: inject the native row provider and/or the `ps` fallback runner.
    static func captureSnapshot(
        rowProvider: () -> [ProcessRow]?,
        runner: (String, [String]) -> String?
    ) -> Snapshot? {
        if let rows = rowProvider(), !rows.isEmpty {
            return buildSnapshot(rows: rows)
        }
        guard let output = runner("/bin/ps", ["-axo", "pid,ppid,args"]) else {
            return nil
        }
        return parse(psArgsOutput: output)
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

    // MARK: - Snapshot building

    /// Folds process rows into the adjacency + identity maps the resolver walks. Shared by
    /// native enumeration and the `ps` fallback so both produce identical `Snapshot` shapes.
    static func buildSnapshot(rows: [ProcessRow]) -> Snapshot {
        var childrenOf: [pid_t: [pid_t]] = [:]
        var commOf: [pid_t: String] = [:]
        var argsOf: [pid_t: String] = [:]

        for row in rows {
            childrenOf[row.ppid, default: []].append(row.pid)
            commOf[row.pid] = row.command
            if let argv = row.argv, !argv.isEmpty {
                argsOf[row.pid] = argv
            }
        }

        return Snapshot(childrenOf: childrenOf, commOf: commOf, argsOf: argsOf)
    }

    // MARK: - `ps` fallback parsing

    /// Parses `ps -axo pid,ppid,args` text into a `Snapshot` (subprocess fallback path).
    static func parse(psArgsOutput: String) -> Snapshot {
        buildSnapshot(rows: psRows(psArgsOutput))
    }

    /// Splits `ps -axo pid,ppid,args` text into rows. `command` is argv[0] (possibly a
    /// full path); `matchProcess` takes its basename, so parsing stays path-policy-free.
    private static func psRows(_ psArgsOutput: String) -> [ProcessRow] {
        psArgsOutput.split(separator: "\n").compactMap { line in
            guard let row = parseRow(line) else { return nil }
            let argv0 = row.rest
                .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                .first.map(String.init) ?? row.rest
            return ProcessRow(pid: row.pid, ppid: row.ppid, command: argv0, argv: row.rest)
        }
    }

    /// Parses one `ps` row of the form `<pid> <ppid> <rest…>`. Returns nil for
    /// header/garbage rows where pid/ppid aren't integers. Shared by any `ps` column
    /// layout whose first two columns are pid and ppid.
    private static func parseRow(_ line: Substring) -> (pid: pid_t, ppid: pid_t, rest: String)? {
        let cols = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard cols.count >= 3,
              let pid = Int32(cols[0].trimmingCharacters(in: .whitespaces)),
              let ppid = Int32(cols[1].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        return (pid, ppid, String(cols[2]).trimmingCharacters(in: .whitespaces))
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

    // MARK: - Native enumeration (libproc + sysctl)

    /// Enumerates the live process table via libproc — no subprocess. argv is fetched via
    /// `KERN_PROCARGS2` only for interpreter processes (`argvNeededBasenames`), since every
    /// other tool is identified by command name alone. Returns nil if enumeration fails,
    /// so `captureSnapshot` falls back to `ps`.
    static func nativeRows() -> [ProcessRow]? {
        let pidCount = proc_listallpids(nil, 0)
        guard pidCount > 0 else { return nil }
        // Headroom: the process set can grow between the count and the fill call.
        let capacity = Int(pidCount) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let filled = proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.stride))
        guard filled > 0 else { return nil }

        var rows: [ProcessRow] = []
        rows.reserveCapacity(Int(filled))
        for index in 0 ..< min(Int(filled), pids.count) {
            let pid = pids[index]
            guard pid > 0 else { continue }
            var info = proc_bsdshortinfo()
            let infoSize = Int32(MemoryLayout<proc_bsdshortinfo>.stride)
            guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, infoSize) == infoSize else {
                continue
            }
            let command = withUnsafeBytes(of: info.pbsi_comm) { buffer in
                String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
            }
            let ppid = pid_t(bitPattern: info.pbsi_ppid)
            let argv = argvNeededBasenames.contains(command.lowercased()) ? processArgv(pid: pid) : nil
            rows.append(ProcessRow(pid: pid, ppid: ppid, command: command, argv: argv))
        }
        return rows.isEmpty ? nil : rows
    }

    /// Reads a process's full command line via `KERN_PROCARGS2`. Same-uid processes are
    /// readable; others may fail (returns nil) — acceptable, as we only need argv for the
    /// user's own interpreter children.
    static func processArgv(pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        if buffer.count > size { buffer.removeLast(buffer.count - size) }
        return parseProcArgs(buffer)
    }

    /// Decodes a `KERN_PROCARGS2` buffer into the space-joined argv (≈ `ps args`).
    /// Layout: `Int32 argc`, the NUL-terminated exec path, NUL padding, then `argc`
    /// NUL-terminated argv strings, then the environment (ignored).
    static func parseProcArgs(_ raw: [UInt8]) -> String? {
        let intSize = MemoryLayout<Int32>.size
        guard raw.count > intSize else { return nil }
        let argc = raw.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0 else { return nil }

        var index = intSize
        // Skip the exec-path string...
        while index < raw.count, raw[index] != 0 {
            index += 1
        }
        // ...and the NUL padding before argv[0].
        while index < raw.count, raw[index] == 0 {
            index += 1
        }

        var args: [String] = []
        var current: [UInt8] = []
        while index < raw.count, args.count < Int(argc) {
            let byte = raw[index]
            index += 1
            if byte == 0 {
                args.append(String(decoding: current, as: UTF8.self))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(byte)
            }
        }
        guard !args.isEmpty else { return nil }
        return args.joined(separator: " ")
    }

    // MARK: - Subprocess fallback

    /// `ps` runner used only when native enumeration fails. Kept internal so tests can
    /// inject deterministic fixtures.
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
