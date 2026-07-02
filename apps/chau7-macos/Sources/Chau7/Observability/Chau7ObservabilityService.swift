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

    private static let eventLimit = 1000
    private static let changeLimit = 2000
    private let queue = DispatchQueue(label: "com.chau7.observability")
    private let launchedAt = Date()
    private var nextSeq: Int64 = 1
    /// The event spine, attached at bootstrap. When present, recordEvent and
    /// the timer APIs ingest structural events into it and this service
    /// becomes a projection: sequence numbers come from the spine (offset by
    /// `spineSeqFloor` so pre-attach records stay monotonic) and topics come
    /// from the envelope's declarative catalog assignment. Weak so a
    /// discarded AppModel (tests) reverts the service to the direct path.
    private weak var spine: EventSpine?
    private var spineSeqFloor: Int64 = 0
    /// Highest sequence ever recorded (events or changes, either path).
    /// `latest_seq` must read this — in spine mode records carry
    /// spine-derived seqs that never touch the internal counter.
    private var lastSeq: Int64 = 0
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
                "latest_seq": lastSeq
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
            lastSeq
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

    /// Attach the spine funnel (bootstrap). Pre-attach records keep their
    /// internal sequence numbers; the floor makes post-attach spine-derived
    /// sequences continue monotonically past them.
    func attachSpine(_ spine: EventSpine) {
        queue.sync {
            self.spine = spine
            self.spineSeqFloor = max(self.nextSeq - 1, self.lastSeq)
        }
    }

    /// Projection entry point: apply a structural envelope delivered by the
    /// spine pump. Timer events update the inventory; everything else lands
    /// in the event ring. Sequence and topics come from the envelope.
    func apply(structural envelope: EventEnvelope) {
        guard let structural = envelope.structuralEvent else { return }
        let seq = queue.sync { spineSeqFloor + Int64(clamping: envelope.seq) }
        let timestampMillis = Int64(envelope.occurredAt.timeIntervalSince1970 * 1000)
        let detail = structural.detail.mapValues(\.foundationValue)

        switch structural.type {
        case "timer_registered", "timer_updated":
            applyTimerEnvelope(structural, detail: detail, seq: seq, timestampMillis: timestampMillis)
        default:
            recordDirect(
                type: structural.type,
                subsystem: structural.subsystem,
                tabID: structural.tabID,
                sessionID: structural.sessionID,
                runID: structural.runID,
                repoPath: structural.repoPath,
                detail: detail,
                explicitSeq: seq,
                explicitTimestampMillis: timestampMillis,
                explicitTopics: envelope.topics
            )
        }
    }

    /// Projection entry point for an accepted AI event: the envelope carries
    /// the spine seq/topics, `adapted` is the pipeline-normalized event.
    /// `.app`-source events stay excluded from the MCP surface (declared
    /// policy pending the per-surface routing stage).
    func applyAccepted(envelope: EventEnvelope, adapted: AIEvent) {
        guard adapted.source != .app else { return }
        let seq = queue.sync { spineSeqFloor + Int64(clamping: envelope.seq) }
        let controlPlaneTabID = adapted.tabID.map { TerminalControlService.shared.controlPlaneTabID(for: $0) }
        recordDirect(
            type: "ai_event",
            subsystem: adapted.source.rawValue,
            tabID: controlPlaneTabID,
            sessionID: adapted.sessionID,
            runID: nil,
            repoPath: adapted.repoPath,
            detail: aiEventDetail(adapted),
            explicitSeq: seq,
            explicitTimestampMillis: Int64(envelope.occurredAt.timeIntervalSince1970 * 1000),
            explicitTopics: envelope.topics
        )
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
        // Spine-attached: producers ingest structural events; this service
        // sees them again via apply(structural:) with the global seq.
        if let spine = queue.sync(execute: { self.spine }),
           let jsonDetail = Self.jsonDetail(from: detail) {
            spine.ingest(structural: StructuralEvent(
                type: type,
                subsystem: subsystem,
                tabID: tabID,
                sessionID: sessionID,
                runID: runID,
                repoPath: repoPath,
                detail: jsonDetail
            ))
            return
        }
        recordDirect(
            type: type,
            subsystem: subsystem,
            tabID: tabID,
            sessionID: sessionID,
            runID: runID,
            repoPath: repoPath,
            detail: detail,
            explicitSeq: nil,
            explicitTimestampMillis: nil,
            explicitTopics: nil
        )
    }

    private func recordDirect(
        type: String,
        subsystem: String,
        tabID: String?,
        sessionID: String?,
        runID: String?,
        repoPath: String?,
        detail: [String: Any],
        explicitSeq: Int64?,
        explicitTimestampMillis: Int64?,
        explicitTopics: [String]?
    ) {
        let timestampMillis = explicitTimestampMillis ?? Int64(Date().timeIntervalSince1970 * 1000)
        let event = queue.sync { () -> EventRecord in
            let seq = explicitSeq ?? allocateSequenceLocked()
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
                topics: explicitTopics ?? EventTopicCatalog.topics(for: EventTopicContext(
                    type: type,
                    subsystem: subsystem,
                    hasTab: tabID != nil,
                    hasSession: sessionID != nil,
                    hasRun: runID != nil,
                    hasRepo: repoPath != nil
                )),
                type: type,
                subsystem: subsystem,
                payload: eventDictionary(event)
            )
            return event
        }
        dispatchChangeIfNeeded(seq: event.seq)
    }

    private static func jsonDetail(from detail: [String: Any]) -> [String: JSONValue]? {
        var converted: [String: JSONValue] = [:]
        for (key, value) in detail {
            guard let jsonValue = JSONValue.from(any: value) else {
                // Unconvertible payloads (rare) fall back to the direct path.
                return nil
            }
            converted[key] = jsonValue
        }
        return converted
    }

    private func aiEventDetail(_ event: AIEvent) -> [String: Any] {
        ([
            "event_type": event.type,
            "tool": event.tool,
            "message": event.message,
            "source": event.source.rawValue,
            "reliability": event.reliability.rawValue,
            "producer": event.producer as Any,
            "notification_type": event.notificationType as Any,
            "title": event.title as Any,
            "timestamp": event.ts
        ] as [String: Any]).compactMapValues { $0 }
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
        // Spine-attached: the change rides the global sequence so the MCP
        // change feed keeps one monotonic space (previously timer changes
        // consumed the same internal counter as events).
        if let spine = queue.sync(execute: { self.spine }) {
            spine.ingest(structural: timerStructuralEvent(type: "timer_registered", record: record))
            return
        }
        let changeSeq = queue.sync { () -> Int64 in
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
        mutateTimer(id) { $0.active = active }
    }

    func updateTimerScope(_ id: String, tabID: String?, sessionID: String?) {
        mutateTimer(id) { record in
            record.tabID = tabID
            record.sessionID = sessionID
        }
    }

    /// Apply `mutation` to a timer record under `queue`, append a
    /// `timer_updated` change record, and dispatch outside the queue.
    /// No-op when the timer id is unknown.
    private func mutateTimer(_ id: String, applying mutation: (inout TimerRecord) -> Void) {
        let spineAndRecord = queue.sync { () -> (EventSpine, TimerRecord)? in
            guard let spine = self.spine, var record = self.timers[id] else { return nil }
            mutation(&record)
            return (spine, record)
        }
        if let (spine, record) = spineAndRecord {
            spine.ingest(structural: timerStructuralEvent(type: "timer_updated", record: record))
            return
        }
        let changeSeq = queue.sync { () -> Int64? in
            guard var record = self.timers[id] else { return nil }
            mutation(&record)
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

    /// Encode a timer record as a structural spine event.
    private func timerStructuralEvent(type: String, record: TimerRecord) -> StructuralEvent {
        var detail: [String: JSONValue] = [
            "id": .string(record.id),
            "kind": .string(record.kind),
            "label": .string(record.label),
            "queue_label": .string(record.queueLabel),
            "active": .bool(record.active)
        ]
        if let intervalMs = record.intervalMs { detail["interval_ms"] = .number(intervalMs) }
        if let leewayMs = record.leewayMs { detail["leeway_ms"] = .number(leewayMs) }
        if let tabID = record.tabID { detail["tab_id"] = .string(tabID) }
        if let sessionID = record.sessionID { detail["session_id"] = .string(sessionID) }
        return StructuralEvent(
            type: type,
            subsystem: record.subsystem,
            tabID: record.tabID,
            sessionID: record.sessionID,
            detail: detail
        )
    }

    /// Apply-side of the timer path: rebuild the record from the envelope,
    /// update the inventory, and append the change with the spine-derived
    /// seq. Topics stay ["timer-inventory"] for parity with the legacy feed.
    private func applyTimerEnvelope(
        _ structural: StructuralEvent,
        detail: [String: Any],
        seq: Int64,
        timestampMillis: Int64
    ) {
        guard let id = detail["id"] as? String else { return }
        let record = TimerRecord(
            id: id,
            kind: detail["kind"] as? String ?? "",
            label: detail["label"] as? String ?? "",
            subsystem: structural.subsystem,
            queueLabel: detail["queue_label"] as? String ?? "",
            intervalMs: detail["interval_ms"] as? Double,
            leewayMs: detail["leeway_ms"] as? Double,
            active: detail["active"] as? Bool ?? false,
            tabID: detail["tab_id"] as? String,
            sessionID: detail["session_id"] as? String
        )
        let changeSeq = queue.sync { () -> Int64 in
            self.timers[id] = record
            appendChangeLocked(
                seq: seq,
                timestampMillis: timestampMillis,
                topics: ["timer-inventory"],
                type: structural.type,
                subsystem: structural.subsystem,
                payload: timerDictionary(record)
            )
            return seq
        }
        dispatchChangeIfNeeded(seq: changeSeq)
    }

    func resetForTests() {
        queue.sync {
            nextSeq = 1
            spine = nil
            spineSeqFloor = 0
            lastSeq = 0
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

    private func appendChangeLocked(
        seq: Int64,
        timestampMillis: Int64,
        topics: [String],
        type: String,
        subsystem: String,
        payload: [String: Any]
    ) {
        lastSeq = max(lastSeq, seq)
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
