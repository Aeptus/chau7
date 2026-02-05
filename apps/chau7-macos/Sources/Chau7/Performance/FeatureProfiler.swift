import Foundation
import os.log

enum FeatureMetric: String, CaseIterable, Identifiable {
    case outputProcessing = "Output"
    case terminalRender = "Render"
    case highlightDraw = "Highlight"
    case dangerScan = "Danger Scan"
    case ansiParse = "ANSI Parse"
    case localEcho = "Local Echo"
    case semantic = "Semantic"
    case aiDetect = "AI Detect"
    case remoteOutput = "Remote Output"

    var id: String { rawValue }

    var displayName: String { rawValue }

    var signpostName: StaticString {
        switch self {
        case .outputProcessing: return "OutputProcessing"
        case .terminalRender: return "TerminalRender"
        case .highlightDraw: return "HighlightDraw"
        case .dangerScan: return "DangerScan"
        case .ansiParse: return "AnsiParse"
        case .localEcho: return "LocalEcho"
        case .semantic: return "Semantic"
        case .aiDetect: return "AIDetect"
        case .remoteOutput: return "RemoteOutput"
        }
    }
}

struct FeatureTotals: Equatable {
    var totalMs: Double = 0
    var count: Int = 0
    var maxMs: Double = 0
    var totalBytes: Int = 0

    mutating func add(durationMs: Double, bytes: Int) {
        totalMs += durationMs
        count += 1
        if durationMs > maxMs {
            maxMs = durationMs
        }
        if bytes > 0 {
            totalBytes += bytes
        }
    }

    var averageMs: Double {
        guard count > 0 else { return 0 }
        return totalMs / Double(count)
    }
}

struct FeatureEvent: Identifiable, Equatable {
    let id = UUID()
    let feature: FeatureMetric
    let durationMs: Int
    let bytes: Int
    let timestamp: Date
    let metadata: String?
}

final class FeatureProfiler {
    static let shared = FeatureProfiler()

    struct Snapshot {
        let asOf: Date
        let totalsLast10s: [FeatureMetric: FeatureTotals]
        let totalsLast60s: [FeatureMetric: FeatureTotals]
        let recentEvents: [FeatureEvent]

        static let empty = Snapshot(
            asOf: Date.distantPast,
            totalsLast10s: [:],
            totalsLast60s: [:],
            recentEvents: []
        )
    }

    struct Token {
        let feature: FeatureMetric
        let startTime: CFAbsoluteTime
        let signpostId: OSSignpostID
        let bytes: Int
        let metadata: String?
    }

    private struct Bucket {
        let second: Int
        var totals: [FeatureMetric: FeatureTotals]
    }

    private let queue = DispatchQueue(label: "com.chau7.featureProfiler", qos: .utility)
    private var buckets: [Bucket] = []
    private var events: [FeatureEvent] = []
    private let bucketCapacitySeconds = 120
    private let eventCapacity = 300

    private let signpostLog = OSLog(subsystem: "com.chau7", category: "performance")

    private init() {}

    func begin(_ feature: FeatureMetric, bytes: Int? = nil, metadata: String? = nil) -> Token {
        let signpostId = OSSignpostID(log: signpostLog)
        os_signpost(.begin, log: signpostLog, name: feature.signpostName, signpostID: signpostId)
        return Token(
            feature: feature,
            startTime: CFAbsoluteTimeGetCurrent(),
            signpostId: signpostId,
            bytes: bytes ?? 0,
            metadata: metadata
        )
    }

    func end(_ token: Token) {
        let durationMs = (CFAbsoluteTimeGetCurrent() - token.startTime) * 1000.0
        os_signpost(.end, log: signpostLog, name: token.feature.signpostName, signpostID: token.signpostId)
        record(
            feature: token.feature,
            durationMs: durationMs,
            bytes: token.bytes,
            metadata: token.metadata
        )
    }

    func record(feature: FeatureMetric, durationMs: Double, bytes: Int = 0, metadata: String? = nil) {
        let timestamp = Date()
        let event = FeatureEvent(
            feature: feature,
            durationMs: Int(durationMs.rounded()),
            bytes: bytes,
            timestamp: timestamp,
            metadata: metadata
        )
        let currentSecond = Int(timestamp.timeIntervalSince1970)
        queue.async { [weak self] in
            guard let self else { return }

            if var last = self.buckets.last, last.second == currentSecond {
                var totals = last.totals[feature] ?? FeatureTotals()
                totals.add(durationMs: durationMs, bytes: bytes)
                last.totals[feature] = totals
                self.buckets[self.buckets.count - 1] = last
            } else {
                var totals = FeatureTotals()
                totals.add(durationMs: durationMs, bytes: bytes)
                let bucket = Bucket(second: currentSecond, totals: [feature: totals])
                self.buckets.append(bucket)
                if self.buckets.count > self.bucketCapacitySeconds {
                    self.buckets.removeFirst(self.buckets.count - self.bucketCapacitySeconds)
                }
            }

            self.events.append(event)
            if self.events.count > self.eventCapacity {
                self.events.removeFirst(self.events.count - self.eventCapacity)
            }
        }
    }

    func snapshot() -> Snapshot {
        let now = Date()
        let nowSecond = Int(now.timeIntervalSince1970)
        return queue.sync {
            let totals10 = totalsForWindow(from: nowSecond - 9)
            let totals60 = totalsForWindow(from: nowSecond - 59)
            return Snapshot(
                asOf: now,
                totalsLast10s: totals10,
                totalsLast60s: totals60,
                recentEvents: events.reversed()
            )
        }
    }

    private func totalsForWindow(from startSecond: Int) -> [FeatureMetric: FeatureTotals] {
        var totals: [FeatureMetric: FeatureTotals] = [:]
        for bucket in buckets where bucket.second >= startSecond {
            for (feature, stats) in bucket.totals {
                var current = totals[feature] ?? FeatureTotals()
                current.totalMs += stats.totalMs
                current.count += stats.count
                current.maxMs = max(current.maxMs, stats.maxMs)
                current.totalBytes += stats.totalBytes
                totals[feature] = current
            }
        }
        return totals
    }
}
