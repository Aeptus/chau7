import Foundation
import Chau7Core

final class Chau7ObservabilityService {
    static let shared = Chau7ObservabilityService()

    typealias ChangePayload = [String: Any]

    private struct EventRecord {
        let seq: Int64
        let id: String
        let timestampMillis: Int64
        let type: String
        let subsystem: String
        let tabID: String?
        let sessionID: String?
        let runID: String?
        let repoPath: String?
        let detail: [String: Any]
    }

    private struct TimerRecord {
        let id: String
        var kind: String
        var label: String
        var subsystem: String
        var queueLabel: String
        var intervalMs: Double?
        var leewayMs: Double?
        var active: Bool
        var tabID: String?
        var sessionID: String?
    }

    private struct ChangeRecord {
        let seq: Int64
        let timestampMillis: Int64
        let topics: [String]
        let type: String
        let subsystem: String
        let payload: [String: Any]
    }

    private struct ListenerRecord {
        let topics: Set<String>?
        let handler: (ChangePayload) -> Void
    }

    private static let eventLimit = 1_000
    private static let changeLimit = 2_000
    private let queue = DispatchQueue(label: "com.chau7.observability")
    private let launchedAt = Date()
    private var nextSeq: Int64 = 1
    private var events: [EventRecord] = []
    private var changes: [ChangeRecord] = []
    private var timers: [String: TimerRecord] = [:]
    private var listeners: [UUID: ListenerRecord] = [:]

    private init() {}

    func runtimeInfoJSON() -> String {
        encode(payload: runtimeInfoPayload())
    }

    func runtimeEventsJSON(sinceMillis: Int64?, limit: Int) -> String {
        let clampedLimit = min(max(limit, 1), 500)
        let payload: [String: Any] = queue.sync {
            let filtered = events.filter { event in
                guard let sinceMillis else { return true }
                return event.timestampMillis >= sinceMillis
            }
            let sliced = Array(filtered.suffix(clampedLimit))
            return [
                "events": sliced.map(eventDictionary),
                "latest_seq": max(nextSeq - 1, 0)
            ]
        }
        return encode(payload: payload)
    }

    func timerInventoryJSON() -> String {
        let payload: [String: Any] = queue.sync {
            timerInventoryPayload()
        }
        return encode(payload: payload)
    }

    /// Thread-safe timer inventory snapshot. Equivalent to calling
    /// `timerInventoryPayload()` under the observability queue lock — use
    /// this from external callers that don't already hold the lock.
    /// Reading `timers` without the lock races with every
    /// `registerTimer` / `setTimerActive` / `updateTimerScope` and can
    /// crash on concurrent dictionary mutation.
    func timerInventorySnapshot() -> [String: Any] {
        queue.sync { timerInventoryPayload() }
    }

    func latestSequence() -> Int64 {
        queue.sync {
            max(nextSeq - 1, 0)
        }
    }

    func changePayloads(sinceSeq: Int64?, topics: [String]?, limit: Int) -> [[String: Any]] {
        let requestedTopics = normalizedTopics(topics)
        let clampedLimit = min(max(limit, 1), 500)
        return queue.sync {
            let filtered = changes.filter { change in
                if let sinceSeq, change.seq <= sinceSeq {
                    return false
                }
                guard let requestedTopics else { return true }
                return !requestedTopics.isDisjoint(with: change.topics)
            }
            return Array(filtered.suffix(clampedLimit)).map(changeDictionary)
        }
    }

    func oldestAvailableChangeSequence() -> Int64? {
        queue.sync {
            changes.first?.seq
        }
    }

    func addChangeListener(topics: [String]?, handler: @escaping (ChangePayload) -> Void) -> UUID {
        let token = UUID()
        queue.sync {
            listeners[token] = ListenerRecord(
                topics: normalizedTopics(topics),
                handler: handler
            )
        }
        return token
    }

    func removeChangeListener(_ token: UUID) {
        _ = queue.sync {
            listeners.removeValue(forKey: token)
        }
    }

    func recordEvent(
        type: String,
        subsystem: String,
        tabID: String? = nil,
        sessionID: String? = nil,
        runID: String? = nil,
        repoPath: String? = nil,
        detail: [String: Any] = [:]
    ) {
        let timestampMillis = Int64(Date().timeIntervalSince1970 * 1000)
        let event = queue.sync { () -> EventRecord in
            let seq = allocateSequenceLocked()
            let event = EventRecord(
                seq: seq,
                id: "evt_\(seq)",
                timestampMillis: timestampMillis,
                type: type,
                subsystem: subsystem,
                tabID: tabID,
                sessionID: sessionID,
                runID: runID,
                repoPath: repoPath,
                detail: detail
            )
            self.events.append(event)
            if self.events.count > Self.eventLimit {
                self.events.removeFirst(self.events.count - Self.eventLimit)
            }
            appendChangeLocked(
                seq: seq,
                timestampMillis: timestampMillis,
                topics: topicsForEvent(type: type, subsystem: subsystem, tabID: tabID, sessionID: sessionID, runID: runID, repoPath: repoPath),
                type: type,
                subsystem: subsystem,
                payload: eventDictionary(event)
            )
            return event
        }
        dispatchChangeIfNeeded(seq: event.seq)
    }

    func recordEvent(
        type: String,
        subsystem: String,
        nativeTabID: UUID?,
        sessionID: String? = nil,
        runID: String? = nil,
        repoPath: String? = nil,
        detail: [String: Any] = [:]
    ) {
        let controlPlaneTabID = nativeTabID.map { TerminalControlService.shared.controlPlaneTabID(for: $0) }
        recordEvent(
            type: type,
            subsystem: subsystem,
            tabID: controlPlaneTabID,
            sessionID: sessionID,
            runID: runID,
            repoPath: repoPath,
            detail: detail
        )
    }

    func recordAIEvent(_ event: AIEvent) {
        guard event.source != .app else { return }
        recordEvent(
            type: "ai_event",
            subsystem: event.source.rawValue,
            nativeTabID: event.tabID,
            sessionID: event.sessionID,
            repoPath: event.repoPath,
            detail: [
                "event_type": event.type,
                "tool": event.tool,
                "message": event.message,
                "source": event.source.rawValue,
                "reliability": event.reliability.rawValue,
                "producer": event.producer as Any,
                "notification_type": event.notificationType as Any,
                "title": event.title as Any,
                "timestamp": event.ts
            ].compactMapValues { $0 }
        )
    }

    func registerTimer(
        id: String,
        kind: String,
        label: String,
        subsystem: String,
        queueLabel: String,
        intervalMs: Double?,
        leewayMs: Double?,
        active: Bool,
        tabID: String? = nil,
        sessionID: String? = nil
    ) {
        let changeSeq = queue.sync { () -> Int64 in
            let record = TimerRecord(
                id: id,
                kind: kind,
                label: label,
                subsystem: subsystem,
                queueLabel: queueLabel,
                intervalMs: intervalMs,
                leewayMs: leewayMs,
                active: active,
                tabID: tabID,
                sessionID: sessionID
            )
            self.timers[id] = record
            let seq = allocateSequenceLocked()
            appendChangeLocked(
                seq: seq,
                timestampMillis: Int64(Date().timeIntervalSince1970 * 1000),
                topics: ["timer-inventory"],
                type: "timer_registered",
                subsystem: subsystem,
                payload: timerDictionary(record)
            )
            return seq
        }
        dispatchChangeIfNeeded(seq: changeSeq)
    }

    func setTimerActive(_ id: String, active: Bool) {
        let changeSeq = queue.sync { () -> Int64? in
            guard var record = self.timers[id] else { return nil }
            record.active = active
            self.timers[id] = record
            let seq = allocateSequenceLocked()
            appendChangeLocked(
                seq: seq,
                timestampMillis: Int64(Date().timeIntervalSince1970 * 1000),
                topics: ["timer-inventory"],
                type: "timer_updated",
                subsystem: record.subsystem,
                payload: timerDictionary(record)
            )
            return seq
        }
        if let changeSeq {
            dispatchChangeIfNeeded(seq: changeSeq)
        }
    }

    func updateTimerScope(_ id: String, tabID: String?, sessionID: String?) {
        let changeSeq = queue.sync { () -> Int64? in
            guard var record = self.timers[id] else { return nil }
            record.tabID = tabID
            record.sessionID = sessionID
            self.timers[id] = record
            let seq = allocateSequenceLocked()
            appendChangeLocked(
                seq: seq,
                timestampMillis: Int64(Date().timeIntervalSince1970 * 1000),
                topics: ["timer-inventory"],
                type: "timer_updated",
                subsystem: record.subsystem,
                payload: timerDictionary(record)
            )
            return seq
        }
        if let changeSeq {
            dispatchChangeIfNeeded(seq: changeSeq)
        }
    }

    func resetForTests() {
        queue.sync {
            nextSeq = 1
            events.removeAll()
            changes.removeAll()
            timers.removeAll()
            listeners.removeAll()
        }
    }

    func runtimeInfoPayload() -> [String: Any] {
        let info = Bundle.main.infoDictionary ?? [:]
        let launchTime = DateFormatters.iso8601.string(from: launchedAt)
        return [
            "app_version": info["CFBundleShortVersionString"] as? String ?? "unknown",
            "build_number": info["CFBundleVersion"] as? String ?? "unknown",
            "build_sha": info["Chau7BuildGitSHA"] as? String ?? "unknown",
            "build_timestamp": info["Chau7BuildTimestamp"] as? String ?? "unknown",
            "build_channel": info["Chau7BuildChannel"] as? String ?? "unknown",
            "bundle_id": info["CFBundleIdentifier"] as? String ?? "unknown",
            "process_id": ProcessInfo.processInfo.processIdentifier,
            "launch_time": launchTime,
            "session_started_at": launchTime,
            "mcp_protocol_version": "2025-11-25",
            "observability_schema_version": 1
        ]
    }

    func timerInventoryPayload() -> [String: Any] {
        let sortedTimers = timers.values.sorted { lhs, rhs in
            lhs.id < rhs.id
        }
        return [
            "timers": sortedTimers.map(timerDictionary)
        ]
    }

    private func eventDictionary(_ event: EventRecord) -> [String: Any] {
        var payload: [String: Any] = [
            "seq": event.seq,
            "id": event.id,
            "timestamp_millis": event.timestampMillis,
            "type": event.type,
            "subsystem": event.subsystem,
            "detail": event.detail
        ]
        payload["tab_id"] = event.tabID
        payload["session_id"] = event.sessionID
        payload["run_id"] = event.runID
        payload["repo_path"] = event.repoPath
        return payload.compactMapValues { $0 }
    }

    private func timerDictionary(_ timer: TimerRecord) -> [String: Any] {
        var payload: [String: Any] = [
            "id": timer.id,
            "kind": timer.kind,
            "label": timer.label,
            "subsystem": timer.subsystem,
            "queue_label": timer.queueLabel,
            "active": timer.active
        ]
        payload["interval_ms"] = timer.intervalMs
        payload["leeway_ms"] = timer.leewayMs
        payload["tab_id"] = timer.tabID
        payload["session_id"] = timer.sessionID
        return payload.compactMapValues { $0 }
    }

    private func normalizedTopics(_ topics: [String]?) -> Set<String>? {
        guard let topics else { return nil }
        let normalized = Set(topics.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
        return normalized.isEmpty ? nil : normalized
    }

    private func allocateSequenceLocked() -> Int64 {
        let seq = nextSeq
        nextSeq += 1
        return seq
    }

    private func topicsForEvent(
        type: String,
        subsystem: String,
        tabID: String?,
        sessionID: String?,
        runID: String?,
        repoPath: String?
    ) -> [String] {
        var topics = Set<String>(["runtime-events"])
        if tabID != nil || type.hasPrefix("tab_") || subsystem == "tabs" {
            topics.insert("tab-state")
        }
        if subsystem == "mcp_approvals" || type.hasPrefix("approval_") {
            topics.insert("approval-state")
        }
        if runID != nil || type.hasPrefix("telemetry_run_") {
            topics.insert("telemetry-runs")
        }
        if repoPath != nil || type == "ai_event" {
            topics.insert("repo-events")
        }
        if sessionID != nil {
            topics.insert("session-state")
        }
        return Array(topics).sorted()
    }

    private func appendChangeLocked(
        seq: Int64,
        timestampMillis: Int64,
        topics: [String],
        type: String,
        subsystem: String,
        payload: [String: Any]
    ) {
        guard !topics.isEmpty else { return }
        changes.append(
            ChangeRecord(
                seq: seq,
                timestampMillis: timestampMillis,
                topics: topics,
                type: type,
                subsystem: subsystem,
                payload: payload
            )
        )
        if changes.count > Self.changeLimit {
            changes.removeFirst(changes.count - Self.changeLimit)
        }
    }

    private func changeDictionary(_ change: ChangeRecord) -> [String: Any] {
        [
            "seq": change.seq,
            "timestamp_millis": change.timestampMillis,
            "topics": change.topics,
            "type": change.type,
            "subsystem": change.subsystem,
            "payload": change.payload
        ]
    }

    private func dispatchChangeIfNeeded(seq: Int64) {
        let listenersToNotify: [(handler: (ChangePayload) -> Void, payload: ChangePayload)] = queue.sync {
            // Look up the specific change by seq rather than trusting
            // `changes.last`. Every record-like entry point (`recordEvent`,
            // `registerTimer`, `setTimerActive`, `updateTimerScope`) appends
            // inside one `queue.sync` and dispatches inside a *second*
            // `queue.sync` — a serial queue only enforces mutual exclusion
            // per block, so a concurrent recorder can slip in between and
            // advance `changes.last` past our seq. The old `changes.last?.seq
            // == seq` guard would then silently drop every listener
            // notification for our change. `last(where:)` searches backward
            // and hits on the first element for a just-allocated seq; the
            // bounded `changes` ring keeps worst case cheap.
            guard let change = changes.last(where: { $0.seq == seq }) else { return [] }
            let payload = changeDictionary(change)
            return listeners.compactMap { _, listener in
                if let topics = listener.topics, topics.isDisjoint(with: change.topics) {
                    return nil
                }
                return (listener.handler, payload)
            }
        }

        for entry in listenersToNotify {
            entry.handler(entry.payload)
        }
    }

    private func encode(payload: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"failed_to_encode_observability_payload\"}"
        }
        return string
    }
}
