import Foundation
import Chau7Core

enum HistorySessionState: String {
    case active
    case idle
    case closed
}

final class HistoryIdleMonitor {
    private let fileURL: URL
    private let idleSecondsProvider: () -> TimeInterval
    private let staleSecondsProvider: () -> TimeInterval
    private let onEntry: ((HistoryEntry) -> Void)?
    private let onStateChange: ((String, HistorySessionState, Date, TimeInterval?) -> Void)?
    private let onIdle: (HistoryEntry, TimeInterval) -> Void

    private var tailer: FileTailer<HistoryEntry>?
    private var timer: DispatchSourceTimer?
    private var lastSeen: [String: Date] = [:]
    private var lastNotified: [String: Date] = [:]
    private var lastEntry: [String: HistoryEntry] = [:]
    /// Sessions that have been notified as idle and haven't had real user activity since.
    /// Prevents re-firing idle callbacks on heartbeat/status entries.
    private var idleNotified: Set<String> = []
    private var closedSessions = BoundedSet<String>(maxCount: AppConstants.Limits.maxClosedSessions)
    private let queue = DispatchQueue(label: "com.chau7.historyIdle")
    private let minimumCheckInterval: TimeInterval = 1.0

    init(
        fileURL: URL,
        idleSecondsProvider: @escaping () -> TimeInterval,
        staleSecondsProvider: @escaping () -> TimeInterval,
        onEntry: ((HistoryEntry) -> Void)? = nil,
        onStateChange: ((String, HistorySessionState, Date, TimeInterval?) -> Void)? = nil,
        onIdle: @escaping (HistoryEntry, TimeInterval) -> Void
    ) {
        self.fileURL = fileURL
        self.idleSecondsProvider = idleSecondsProvider
        self.staleSecondsProvider = staleSecondsProvider
        self.onEntry = onEntry
        self.onStateChange = onStateChange
        self.onIdle = onIdle
    }

    func start() {
        stop()
        Log.trace("Idle monitor start. path=\(fileURL.path)")

        let tailer = FileTailer<HistoryEntry>.historyTailer(fileURL: fileURL) { [weak self] entry in
            self?.record(entry: entry)
            self?.onEntry?(entry)
        }
        tailer.start()
        self.tailer = tailer
        queue.async {
            self.scheduleNextCheck(now: Date())
        }
    }

    func stop() {
        tailer?.stop()
        tailer = nil
        timer?.cancel()
        timer = nil
        lastSeen.removeAll()
        lastNotified.removeAll()
        lastEntry.removeAll()
        idleNotified.removeAll()
        closedSessions.removeAll(keepingCapacity: false)
        Log.trace("Idle monitor stop. path=\(fileURL.path)")
    }

    private func record(entry: HistoryEntry) {
        queue.async {
            let now = Date()
            if entry.isExit {
                self.closedSessions.insert(entry.sessionId)
                self.lastSeen.removeValue(forKey: entry.sessionId)
                self.lastEntry.removeValue(forKey: entry.sessionId)
                self.lastNotified.removeValue(forKey: entry.sessionId)
                self.idleNotified.remove(entry.sessionId)
                self.onStateChange?(entry.sessionId, .closed, now, nil)
                Log.trace("Idle monitor closed by exit marker. session=\(entry.sessionId)")
                self.scheduleNextCheck(now: now)
                return
            }

            if self.closedSessions.contains(entry.sessionId) {
                self.closedSessions.remove(entry.sessionId)
            }

            self.lastSeen[entry.sessionId] = now
            self.lastEntry[entry.sessionId] = entry

            // Only clear idle dedup for entries with meaningful content (user activity).
            // Heartbeat/status entries have empty summaries and shouldn't re-trigger
            // idle notifications — the session hasn't actually become active again.
            let isUserActivity = !entry.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isUserActivity {
                self.idleNotified.remove(entry.sessionId)
                self.lastNotified.removeValue(forKey: entry.sessionId)
            }
            self.onStateChange?(entry.sessionId, .active, now, nil)
            Log.trace("Idle monitor record. session=\(entry.sessionId) userActivity=\(isUserActivity)")
            self.scheduleNextCheck(now: now)
        }
    }

    private func checkIdle() {
        let now = Date()
        let idleSeconds = max(1.0, idleSecondsProvider())
        let staleSeconds = max(idleSeconds + 1.0, staleSecondsProvider())
        var staleSessionIds: [String] = []

        let snapshot = lastSeen
        for (sessionId, lastSeenAt) in snapshot {
            let idleFor = now.timeIntervalSince(lastSeenAt)
            if idleFor < idleSeconds { continue }

            if idleFor >= staleSeconds {
                closedSessions.insert(sessionId)
                staleSessionIds.append(sessionId)
                continue
            }

            // Already notified idle for this session — don't re-fire until
            // real user activity clears the flag in record(entry:).
            if idleNotified.contains(sessionId) { continue }

            let entry = lastEntry[sessionId] ?? HistoryEntry(
                sessionId: sessionId,
                timestamp: now.timeIntervalSince1970,
                summary: "",
                isExit: false
            )
            onIdle(entry, idleFor)
            idleNotified.insert(sessionId)
            lastNotified[sessionId] = now
            onStateChange?(sessionId, .idle, lastSeenAt, idleFor)
            Log.trace("Idle monitor notify. session=\(sessionId) idleFor=\(Int(idleFor))")
        }

        for sessionId in staleSessionIds {
            guard let lastSeenAt = lastSeen[sessionId] else { continue }
            let idleFor = now.timeIntervalSince(lastSeenAt)
            onStateChange?(sessionId, .closed, lastSeenAt, idleFor)
            Log.trace("Idle monitor marked stale. session=\(sessionId) idleFor=\(Int(idleFor))")

            lastSeen.removeValue(forKey: sessionId)
            lastNotified.removeValue(forKey: sessionId)
            lastEntry.removeValue(forKey: sessionId)
            idleNotified.remove(sessionId)
        }

        scheduleNextCheck(now: now)
    }

    private func scheduleNextCheck(now: Date) {
        guard !lastSeen.isEmpty else {
            timer?.cancel()
            timer = nil
            return
        }

        guard let delay = MonitoringSchedule.nextHistoryCheckDelay(
            now: now,
            minimumCheckInterval: minimumCheckInterval,
            idleSeconds: idleSecondsProvider(),
            staleSeconds: staleSecondsProvider(),
            lastSeen: lastSeen,
            idleNotified: idleNotified
        ) else {
            return
        }

        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            self?.checkIdle()
        }
        timer.resume()
        self.timer = timer
    }
}
