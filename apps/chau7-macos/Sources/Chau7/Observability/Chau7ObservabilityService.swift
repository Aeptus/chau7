import Foundation
import Chau7Core

final class Chau7ObservabilityService {
    static let shared = Chau7ObservabilityService()

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

    private static let eventLimit = 1_000
    private let queue = DispatchQueue(label: "com.chau7.observability")
    private let launchedAt = Date()
    private var nextSeq: Int64 = 1
    private var events: [EventRecord] = []
    private var timers: [String: TimerRecord] = [:]

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
            let sortedTimers = timers.values.sorted { lhs, rhs in
                lhs.id < rhs.id
            }
            return [
                "timers": sortedTimers.map(timerDictionary)
            ]
        }
        return encode(payload: payload)
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
        queue.sync {
            let seq = self.nextSeq
            self.nextSeq += 1
            self.events.append(
                EventRecord(
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
            )
            if self.events.count > Self.eventLimit {
                self.events.removeFirst(self.events.count - Self.eventLimit)
            }
        }
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
        queue.sync {
            self.timers[id] = TimerRecord(
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
        }
    }

    func setTimerActive(_ id: String, active: Bool) {
        queue.sync {
            guard var record = self.timers[id] else { return }
            record.active = active
            self.timers[id] = record
        }
    }

    func resetForTests() {
        queue.sync {
            nextSeq = 1
            events.removeAll()
            timers.removeAll()
        }
    }

    private func runtimeInfoPayload() -> [String: Any] {
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

    private func encode(payload: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"failed_to_encode_observability_payload\"}"
        }
        return string
    }
}
