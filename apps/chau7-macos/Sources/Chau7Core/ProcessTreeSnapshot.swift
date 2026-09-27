#if os(macOS)
import Darwin
import Foundation

/// A parsed, point-in-time view of the machine's process table, built from
/// `ps -axo pid=,ppid=,command=`.
///
/// Extracted from `TerminalSessionModel.captureDescendantPIDs` so the parse and
/// the traversal can be unit-tested, and — more importantly — so the result can
/// be *shared*. The process table is global, not per-session: every
/// `TerminalSessionModel` asking "who are my shell's descendants" was spawning
/// its own `/bin/ps` and paying fork+exec+read for it. At app termination that
/// ran serially on the main thread, once per session, which is the "Chau7
/// won't quit" beachball.
public struct ProcessTreeSnapshot: Sendable {
    public struct Node: Sendable, Equatable {
        public let pid: pid_t
        public let parentPID: pid_t
        public let command: String

        public init(pid: pid_t, parentPID: pid_t, command: String) {
            self.pid = pid
            self.parentPID = parentPID
            self.command = command
        }
    }

    public let capturedAt: Date
    private let childrenOf: [pid_t: [pid_t]]
    private let rowsByPID: [pid_t: Node]

    /// - Parameters:
    ///   - psOutput: Raw `ps -axo pid=,ppid=,command=` output. Malformed lines
    ///     are skipped rather than failing the whole snapshot, matching the
    ///     original per-line `guard ... else { continue }`.
    ///   - capturedAt: Injected so freshness is testable.
    public init(psOutput: String, capturedAt: Date) {
        self.capturedAt = capturedAt
        var children: [pid_t: [pid_t]] = [:]
        var rows: [pid_t: Node] = [:]

        for line in psOutput.split(separator: "\n") {
            let columns = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard columns.count >= 3,
                  let pid = Int32(columns[0]),
                  let parentPID = Int32(columns[1]) else {
                continue
            }
            let command = String(columns[2]).trimmingCharacters(in: .whitespacesAndNewlines)
            children[parentPID, default: []].append(pid)
            rows[pid] = Node(pid: pid, parentPID: parentPID, command: command)
        }

        self.childrenOf = children
        self.rowsByPID = rows
    }

    public var isEmpty: Bool { rowsByPID.isEmpty }

    /// All descendants of `shellPID` in BFS order (parents before children), so
    /// a kill sweep walks ancestors first.
    ///
    /// A `visited` set makes the walk terminate even if the table contains a
    /// parent/child cycle. The original inline implementation had no such guard
    /// and relied on the invariant that a real `ps` table cannot cycle (each
    /// live process has exactly one parent, and a cycle would need two processes
    /// to be each other's ancestor). That invariant holds for a genuine
    /// snapshot, but this type's initializer is public and accepts arbitrary
    /// text, and a cycle reached through the app-termination path would hang the
    /// main thread forever — a worse outcome than any tree accuracy, and the
    /// precise failure this rework exists to remove. Revisiting a pid is also
    /// just wrong: a pid appears at most once in a real table, so a repeat
    /// carries no new information.
    public func descendants(of shellPID: pid_t) -> [Node] {
        var result: [Node] = []
        var visited: Set<pid_t> = [shellPID]
        var queue: [pid_t] = childrenOf[shellPID] ?? []
        var index = 0
        while index < queue.count {
            let pid = queue[index]
            index += 1
            guard visited.insert(pid).inserted else { continue }
            if let row = rowsByPID[pid] {
                result.append(row)
            }
            if let children = childrenOf[pid] {
                queue.append(contentsOf: children)
            }
        }
        return result
    }

    /// Freshness is a pure function so the cache policy is testable without a
    /// clock. A snapshot at or beyond the TTL is stale.
    public func isFresh(at now: Date, ttl: TimeInterval) -> Bool {
        guard ttl > 0 else { return false }
        return now.timeIntervalSince(capturedAt) < ttl
    }

    /// The command used to capture a snapshot. Centralised so the argument
    /// string cannot drift between the refresh and the fallback path.
    public static let psExecutablePath = "/bin/ps"
    public static let psArguments = ["-axo", "pid=,ppid=,command="]

    /// Runs `ps` and parses the result. Blocking — callers on the main thread
    /// must pass a short `timeout` so N sessions cannot multiply into a hang.
    /// The default 5 s exists for cold-cache correctness, not for hot paths;
    /// hot paths should read `SharedProcessTreeCache` instead.
    public static func capture(timeout: TimeInterval = 5) -> ProcessTreeSnapshot? {
        guard let result = SubprocessRunner.capture(
            executablePath: psExecutablePath,
            arguments: psArguments,
            timeout: timeout
        ), result.completed, result.status == 0 else {
            return nil
        }
        return ProcessTreeSnapshot(
            psOutput: String(decoding: result.stdout, as: UTF8.self),
            capturedAt: Date()
        )
    }
}

/// Process-wide cache of the last `ps` snapshot, refreshed off the main thread.
///
/// The process table is global, so one snapshot answers the descendant query
/// for every session simultaneously. A snapshot taken a moment before a kill is
/// strictly *better* than one taken during it: the group SIGKILL already
/// reaches the shell's own pgid, and the per-descendant sweep exists to catch
/// subprocesses that escaped into their own pgids — a tree that existed
/// moments earlier is exactly the right input for that.
public final class SharedProcessTreeCache: @unchecked Sendable {
    public static let shared = SharedProcessTreeCache()

    /// Long enough that a quit-time read almost always hits, short enough that a
    /// long-running session doesn't act on a stale tree.
    public static let defaultTTL: TimeInterval = 2

    /// TTL for the termination sweep. More generous than `defaultTTL` because a
    /// tree captured a few seconds before a kill is a perfectly good input: the
    /// process-group SIGKILL reaches the shell's own pgid, and the
    /// per-descendant sweep exists to catch subprocesses that escaped into their
    /// own pgids. Missing a subtree spawned in the last instant is far less
    /// costly than making every quit pay a fresh `ps`.
    public static let terminationTTL: TimeInterval = 5

    /// Deadline for the synchronous fallback on a cold cache.
    ///
    /// Sized so a real `ps` actually completes — an earlier revision used 0.3 s
    /// and on a loaded machine that reliably timed out, which returned an EMPTY
    /// tree. That is worse than slow: an empty tree silently skips the
    /// per-descendant kill and leaves orphaned AI subprocesses (Codex/Claude MCP
    /// servers spawned via setsid) running after quit, which is the exact failure
    /// the sweep exists to prevent.
    ///
    /// The cost stays bounded because the cache is process-wide: only the first
    /// session to ask pays this at all, and every later session is served from
    /// the snapshot that first read stored. The pre-rework path paid
    /// `fallbackTimeout x sessionCount` on the main thread.
    public static let terminationFallbackTimeout: TimeInterval = 2

    private let lock = NSLock()
    private var snapshot: ProcessTreeSnapshot?
    private var refreshInFlight = false

    public init() {}

    /// The cached snapshot if it is still within `ttl`. Never captures.
    public func currentSnapshot(
        ttl: TimeInterval = SharedProcessTreeCache.defaultTTL
    ) -> ProcessTreeSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let snapshot, snapshot.isFresh(at: Date(), ttl: ttl) else { return nil }
        return snapshot
    }

    /// Reads the cache, falling back to a bounded synchronous capture on a cold
    /// or stale cache. `fallbackTimeout` must stay small on any path that can
    /// run on the main thread: it is multiplied by the number of sessions.
    public func snapshot(
        ttl: TimeInterval = SharedProcessTreeCache.defaultTTL,
        fallbackTimeout: TimeInterval
    ) -> ProcessTreeSnapshot? {
        if let cached = currentSnapshot(ttl: ttl) { return cached }
        return store(ProcessTreeSnapshot.capture(timeout: fallbackTimeout))
    }

    /// Kicks off a refresh on a utility queue. Re-entrant calls while a refresh
    /// is outstanding are dropped, so a burst of triggers cannot fork-exec `ps`
    /// dozens of times.
    public func refresh() {
        lock.lock()
        if refreshInFlight {
            lock.unlock()
            return
        }
        refreshInFlight = true
        lock.unlock()

        DispatchQueue.global(qos: .utility).async { [self] in
            _ = store(ProcessTreeSnapshot.capture(timeout: 5))
            lock.lock()
            refreshInFlight = false
            lock.unlock()
        }
    }

    @discardableResult
    private func store(_ snapshot: ProcessTreeSnapshot?) -> ProcessTreeSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        // Never let a failed capture evict a good snapshot: a stale tree is
        // still usable for a kill sweep, an absent one is not.
        if let snapshot { self.snapshot = snapshot }
        return snapshot
    }
}
#endif
