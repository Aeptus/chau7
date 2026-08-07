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
    private var lastLogAt: Date
    private var entries: [Key: Aggregate] = [:]

    init(
        logInterval: TimeInterval = 30,
        now: @escaping () -> Date = Date.init
    ) {
        self.logInterval = logInterval
        self.now = now
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
            log(snapshotToLog)
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

    private func log(_ snapshot: Snapshot) {
        let sortedEntries = snapshot.entries.sorted { lhs, rhs in
            let lhsKey = "\(lhs.key.operation.rawValue):\(lhs.key.context.renderPhase):\(lhs.key.context.visibility):\(lhs.key.context.caller)"
            let rhsKey = "\(rhs.key.operation.rawValue):\(rhs.key.context.renderPhase):\(rhs.key.context.visibility):\(rhs.key.context.caller)"
            return lhsKey < rhsKey
        }
        for (key, aggregate) in sortedEntries {
            Log.info(
                String(
                    format: "Terminal work (30s): op=%@ phase=%@ visibility=%@ caller=%@ count=%d bytes=%d total=%.2fms main=%.2fms max=%.2fms",
                    key.operation.rawValue,
                    key.context.renderPhase,
                    key.context.visibility,
                    key.context.caller,
                    aggregate.count,
                    aggregate.bytes,
                    aggregate.totalDurationMs,
                    aggregate.mainThreadDurationMs,
                    aggregate.maxDurationMs
                )
            )
        }
    }
}
