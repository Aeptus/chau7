import Foundation
import Chau7Core

final class WakeupProfiler {
    static let shared = WakeupProfiler()

    private struct Totals {
        var count = 0
        var totalDurationMs: Double = 0
        var maxDurationMs: Double = 0

        mutating func add(durationMs: Double?) {
            count += 1
            guard let durationMs else { return }
            totalDurationMs += durationMs
            if durationMs > maxDurationMs {
                maxDurationMs = durationMs
            }
        }

        var averageDurationMs: Double {
            // swiftlint:disable:next empty_count
            guard count > 0, totalDurationMs > 0 else { return 0 }
            return totalDurationMs / Double(count)
        }
    }

    private let lock = NSLock()
    private var totalsBySource: [String: Totals] = [:]
    private var lastFlushAt = Date()
    private let flushInterval: TimeInterval = 30

    private init() {}

    func record(_ source: String, durationMs: Double? = nil) {
        guard WakeupControl.isEnabled(.instrumentationEnabled) else { return }

        let now = Date()
        var snapshot: [(String, Totals)] = []

        lock.lock()
        var totals = totalsBySource[source] ?? Totals()
        totals.add(durationMs: durationMs)
        totalsBySource[source] = totals

        if now.timeIntervalSince(lastFlushAt) >= flushInterval {
            snapshot = totalsBySource
                .map { ($0.key, $0.value) }
                .sorted { $0.0 < $1.0 }
            totalsBySource.removeAll(keepingCapacity: true)
            lastFlushAt = now
        }
        lock.unlock()

        guard !snapshot.isEmpty else { return }
        let summary = snapshot.map { source, totals in
            if totals.totalDurationMs > 0 {
                return String(
                    format: "%@=%d avg=%.1fms max=%.1fms",
                    source,
                    totals.count,
                    totals.averageDurationMs,
                    totals.maxDurationMs
                )
            }
            return "\(source)=\(totals.count)"
        }
        .joined(separator: " ")
        Log.info("Wakeup profile (30s): \(summary)")
    }
}
