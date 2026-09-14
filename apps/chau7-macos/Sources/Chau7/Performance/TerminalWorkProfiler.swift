import Foundation
import Chau7Core

enum TerminalWorkOperation: String, CaseIterable {
    case getLastOutput
    case getGrid
    case cursorModeRead
    case fullBufferCapture
    case tailBufferCapture
    case terminalStateExtraction
    case terminalStateProcessing
    /// VTE replay of a scrollback disk cache back into the ring. Watched by
    /// the responsiveness gates: sustained >50ms replays mean the reload
    /// should defer until the user scrolls instead of running at promotion.
    case replayBuffer
    /// Tab switch → first committed Metal frame for the incoming view.
    /// The tab-switch latency budget instrument.
    case tabSwitchFirstPaint
}

struct TerminalWorkContext: Hashable {
    let renderPhase: String
    let visibility: String
    let caller: String
}

/// Records terminal backend work with enough context to distinguish live
/// rendering from hidden-tab draining and persistence captures. Aggregates are
/// emitted periodically so profiling does not require per-poll trace logging.
final class TerminalWorkProfiler {
    static let shared = TerminalWorkProfiler()

    struct Key: Hashable {
        let operation: TerminalWorkOperation
        let context: TerminalWorkContext
    }

    struct Aggregate: Equatable {
        var count = 0
        var bytes = 0
        var totalDurationMs = 0.0
        var mainThreadDurationMs = 0.0
        var maxDurationMs = 0.0

        mutating func add(durationMs: Double, bytes: Int, ranOnMainThread: Bool) {
            count += 1
            self.bytes += max(0, bytes)
            totalDurationMs += durationMs
            if ranOnMainThread {
                mainThreadDurationMs += durationMs
            }
            maxDurationMs = max(maxDurationMs, durationMs)
        }
    }

    struct Snapshot {
        let asOf: Date
        let entries: [Key: Aggregate]
    }

    private let lock = NSLock()
    private let logInterval: TimeInterval
    private let now: () -> Date
    private let telemetry: PerformanceTelemetryRecording
    private var lastLogAt: Date
    private var entries: [Key: Aggregate] = [:]

    init(
        logInterval: TimeInterval = 60,
        now: @escaping () -> Date = Date.init,
        telemetry: PerformanceTelemetryRecording = PerformanceTelemetryWriter.shared
    ) {
        self.logInterval = logInterval
        self.now = now
        self.telemetry = telemetry
        self.lastLogAt = now()
    }

    @discardableResult
    func measure<T>(
        _ operation: TerminalWorkOperation,
        context: TerminalWorkContext,
        ranOnMainThread: Bool? = nil,
        bytes: (T) -> Int = { _ in 0 },
        _ body: () -> T
    ) -> T {
        let startedAt = CFAbsoluteTimeGetCurrent()
        let result = body()
        record(
            operation,
            context: context,
            durationMs: (CFAbsoluteTimeGetCurrent() - startedAt) * 1000.0,
            bytes: bytes(result),
            ranOnMainThread: ranOnMainThread ?? Thread.isMainThread
        )
        return result
    }

    func record(
        _ operation: TerminalWorkOperation,
        context: TerminalWorkContext,
        durationMs: Double,
        bytes: Int = 0,
        ranOnMainThread: Bool = Thread.isMainThread
    ) {
        guard WakeupControl.isEnabled(.instrumentationEnabled) else { return }
        let date = now()
        let key = Key(operation: operation, context: context)
        var snapshotToLog: Snapshot?

        lock.lock()
        var aggregate = entries[key] ?? Aggregate()
        aggregate.add(
            durationMs: max(0, durationMs),
            bytes: bytes,
            ranOnMainThread: ranOnMainThread
        )
        entries[key] = aggregate
        if date.timeIntervalSince(lastLogAt) >= logInterval {
            snapshotToLog = Snapshot(asOf: date, entries: entries)
            entries.removeAll(keepingCapacity: true)
            lastLogAt = date
        }
        lock.unlock()

        if let snapshotToLog {
            emit(snapshotToLog)
        }
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(asOf: now(), entries: entries)
    }

    func resetForTesting() {
        lock.lock()
        entries.removeAll()
        lastLogAt = now()
        lock.unlock()
    }

    private func emit(_ snapshot: Snapshot) {
        let sortedEntries = snapshot.entries.sorted { lhs, rhs in
            let lhsKey = "\(lhs.key.operation.rawValue):\(lhs.key.context.renderPhase):\(lhs.key.context.visibility):\(lhs.key.context.caller)"
            let rhsKey = "\(rhs.key.operation.rawValue):\(rhs.key.context.renderPhase):\(rhs.key.context.visibility):\(rhs.key.context.caller)"
            return lhsKey < rhsKey
        }
        let encodedEntries: [[String: Any]] = sortedEntries.map { key, aggregate in
            [
                "operation": key.operation.rawValue,
                "phase": key.context.renderPhase,
                "visibility": key.context.visibility,
                "caller": key.context.caller,
                "count": aggregate.count,
                "bytes": aggregate.bytes,
                "total_duration_ms": aggregate.totalDurationMs,
                "main_thread_duration_ms": aggregate.mainThreadDurationMs,
                "max_duration_ms": aggregate.maxDurationMs
            ]
        }
        telemetry.record(
            category: "terminal_work",
            fields: [
                "interval_seconds": logInterval.isFinite ? logInterval : 0,
                "entries": encodedEntries
            ],
            at: snapshot.asOf
        )
    }
}
