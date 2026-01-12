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
    private var closedSessions = BoundedSet<String>(maxCount: AppConstants.Limits.maxClosedSessions)
    private let queue = DispatchQueue(label: "com.chau7.historyIdle")

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

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.checkIdle()
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        tailer?.stop()
        tailer = nil
        timer?.cancel()
        timer = nil
        lastSeen.removeAll()
        lastNotified.removeAll()
        lastEntry.removeAll()
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
                self.onStateChange?(entry.sessionId, .closed, now, nil)
                Log.trace("Idle monitor closed by exit marker. session=\(entry.sessionId)")
                return
            }

            if self.closedSessions.contains(entry.sessionId) {
                self.closedSessions.remove(entry.sessionId)
            }

            self.lastSeen[entry.sessionId] = now
            self.lastEntry[entry.sessionId] = entry
            self.lastNotified.removeValue(forKey: entry.sessionId)
            self.onStateChange?(entry.sessionId, .active, now, nil)
            Log.trace("Idle monitor record. session=\(entry.sessionId)")
        }
    }

    private func checkIdle() {
        let now = Date()
        let idleSeconds = max(1.0, idleSecondsProvider())
        let staleSeconds = max(idleSeconds + 1.0, staleSecondsProvider())

        for (sessionId, lastSeenAt) in Array(lastSeen) {
            let idleFor = now.timeIntervalSince(lastSeenAt)
            if idleFor < idleSeconds { continue }

            if idleFor >= staleSeconds {
                closedSessions.insert(sessionId)
                lastSeen.removeValue(forKey: sessionId)
                lastEntry.removeValue(forKey: sessionId)
                lastNotified.removeValue(forKey: sessionId)
                onStateChange?(sessionId, .closed, lastSeenAt, idleFor)
                Log.trace("Idle monitor marked stale. session=\(sessionId) idleFor=\(Int(idleFor))")
                continue
            }

            if let lastNotifiedAt = lastNotified[sessionId], lastNotifiedAt >= lastSeenAt {
                continue
            }

            let entry = lastEntry[sessionId] ?? HistoryEntry(
                sessionId: sessionId,
                timestamp: now.timeIntervalSince1970,
                summary: "",
                isExit: false
            )

            onIdle(entry, idleFor)
            lastNotified[sessionId] = now
            onStateChange?(sessionId, .idle, lastSeenAt, idleFor)
            Log.trace("Idle monitor notify. session=\(sessionId) idleFor=\(Int(idleFor))")
        }
    }
}
