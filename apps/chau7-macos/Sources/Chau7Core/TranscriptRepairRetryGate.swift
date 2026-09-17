import Foundation

/// Coalesces concurrent repairs and bounds retries for transient missing or
/// unreadable transcripts. Failed discovery is never stamped as completed.
public final class TranscriptRepairRetryGate: @unchecked Sendable {
    private struct Failure { let count: Int
        let at: Date
    }

    private let lock = NSLock()
    private var inFlight: Set<String> = []
    private var failures: [String: Failure] = [:]

    public init() {}

    public static func delay(afterFailures count: Int) -> TimeInterval {
        switch count {
        case ...0: return 0
        case 1: return 5
        case 2: return 45
        case 3: return 300
        default: return 3600
        }
    }

    public func begin(_ id: String, now: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !inFlight.contains(id) else { return false }
        if let failure = failures[id], now.timeIntervalSince(failure.at) < Self.delay(afterFailures: failure.count) {
            return false
        }
        inFlight.insert(id)
        return true
    }

    public func finish(_ id: String, succeeded: Bool, now: Date) {
        lock.lock()
        defer { lock.unlock() }
        inFlight.remove(id)
        if succeeded {
            failures.removeValue(forKey: id)
        } else {
            failures[id] = Failure(count: min(4, (failures[id]?.count ?? 0) + 1), at: now)
            if failures.count > 512,
               let oldest = failures.min(by: { $0.value.at < $1.value.at })?.key {
                failures.removeValue(forKey: oldest)
            }
        }
    }

    public func deferredIDs(now: Date) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(inFlight.union(failures.compactMap { id, failure in
            now.timeIntervalSince(failure.at) < Self.delay(afterFailures: failure.count) ? id : nil
        })).sorted()
    }
}
