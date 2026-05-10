import Foundation

public enum ProviderLatencyMetricKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case apiRequest = "api_request"
    case firstResponse = "first_response"

    public var id: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .apiRequest:
            return "API Response"
        case .firstResponse:
            return "Round Trip"
        }
    }

    public var shortExplanation: String {
        switch self {
        case .apiRequest:
            return "Successful API call latency using TTFT when available, else round trip."
        case .firstResponse:
            return "Time from a submitted prompt to the first assistant output for that same round."
        }
    }

    public var detailedExplanation: String {
        switch self {
        case .apiRequest:
            return "Measures successful proxy-backed API latency. For streaming calls, Chau7 uses proxy-observed time to first token when available. For non-streaming calls or older rows without TTFT, it falls back to full request round trip time."
        case .firstResponse:
            return "Measures the exact round trip for CLI providers: from the first human prompt in a round to the first assistant output for that same round. Chau7 stores one sample per prompt/response round and falls back to run start when an authoritative transcript begins with assistant output."
        }
    }
}

public enum ProviderLatencyTimeRange: String, CaseIterable, Identifiable, Sendable {
    case today = "Today"
    case week = "7 Days"
    case twoWeeks = "14 Days"
    case month = "30 Days"
    case quarter = "90 Days"
    case allTime = "All Time"

    public var id: String {
        rawValue
    }

    public func startDate(calendar: Calendar = .current, now: Date = Date()) -> Date? {
        switch self {
        case .today:
            return calendar.startOfDay(for: now)
        case .week:
            return calendar.date(byAdding: .day, value: -7, to: now)
        case .twoWeeks:
            return calendar.date(byAdding: .day, value: -14, to: now)
        case .month:
            return calendar.date(byAdding: .day, value: -30, to: now)
        case .quarter:
            return calendar.date(byAdding: .day, value: -90, to: now)
        case .allTime:
            return nil
        }
    }
}

public enum ProviderLatencyBucketKind: String, CaseIterable, Identifiable, Sendable {
    case day = "Per Day"
    case weekday = "Weekday"
    case periodOfDay = "Period"
    case hourOfDay = "Hour"

    public var id: String {
        rawValue
    }
}

public enum LatencyPeriodOfDay: String, CaseIterable, Identifiable, Sendable {
    case night
    case morning
    case afternoon
    case evening

    public var id: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .night:
            return "Night"
        case .morning:
            return "Morning"
        case .afternoon:
            return "Afternoon"
        case .evening:
            return "Evening"
        }
    }

    public static func forHour(_ hour: Int) -> LatencyPeriodOfDay {
        switch hour {
        case 0 ..< 6:
            return .night
        case 6 ..< 12:
            return .morning
        case 12 ..< 18:
            return .afternoon
        default:
            return .evening
        }
    }
}

public struct ProviderLatencySample: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let provider: String
    public let metricKind: ProviderLatencyMetricKind
    public let latencyMs: Int
    public let timestamp: Date
    public let model: String?
    public let sessionID: String?
    public let runID: String?
    public let roundIndex: Int?
    public let projectPath: String?
    public let sourceKind: String

    public init(
        id: String = UUID().uuidString,
        provider: String,
        metricKind: ProviderLatencyMetricKind,
        latencyMs: Int,
        timestamp: Date,
        model: String? = nil,
        sessionID: String? = nil,
        runID: String? = nil,
        roundIndex: Int? = nil,
        projectPath: String? = nil,
        sourceKind: String
    ) {
        self.id = id
        self.provider = provider
        self.metricKind = metricKind
        self.latencyMs = max(0, latencyMs)
        self.timestamp = timestamp
        self.model = model
        self.sessionID = sessionID
        self.runID = runID
        self.roundIndex = roundIndex
        self.projectPath = projectPath
        self.sourceKind = sourceKind
    }
}

public struct ProviderLatencyAggregate: Equatable, Sendable {
    public let count: Int
    public let averageLatencyMs: Double
    public let p50LatencyMs: Int?
    public let p95LatencyMs: Int?
    public let minLatencyMs: Int?
    public let maxLatencyMs: Int?

    public init(
        count: Int,
        averageLatencyMs: Double,
        p50LatencyMs: Int?,
        p95LatencyMs: Int?,
        minLatencyMs: Int?,
        maxLatencyMs: Int?
    ) {
        self.count = count
        self.averageLatencyMs = averageLatencyMs
        self.p50LatencyMs = p50LatencyMs
        self.p95LatencyMs = p95LatencyMs
        self.minLatencyMs = minLatencyMs
        self.maxLatencyMs = maxLatencyMs
    }
}

public struct ProviderLatencyBucketPoint: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let aggregate: ProviderLatencyAggregate

    public init(id: String, label: String, aggregate: ProviderLatencyAggregate) {
        self.id = id
        self.label = label
        self.aggregate = aggregate
    }
}

public struct ProviderActivitySample: Identifiable, Equatable, Sendable {
    public let id: String
    public let provider: String
    public let timestamp: Date
    public let sourceKind: String

    public init(
        id: String = UUID().uuidString,
        provider: String,
        timestamp: Date,
        sourceKind: String
    ) {
        self.id = id
        self.provider = provider
        self.timestamp = timestamp
        self.sourceKind = sourceKind
    }
}

public struct ProviderActivityBucketPoint: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let count: Int

    public init(id: String, label: String, count: Int) {
        self.id = id
        self.label = label
        self.count = count
    }
}

public enum ProviderLatencyAnalytics {
    public static func canonicalLatencySamples(
        _ samples: [ProviderLatencySample]
    ) -> [ProviderLatencySample] {
        var preferredByRunKey: [String: ProviderLatencySample] = [:]
        var passthrough: [ProviderLatencySample] = []

        for sample in samples {
            guard sample.metricKind == .firstResponse,
                  let runID = sample.runID,
                  !runID.isEmpty,
                  let roundIndex = sample.roundIndex else {
                passthrough.append(sample)
                continue
            }

            let key = "\(sample.provider.lowercased())|\(sample.metricKind.rawValue)|\(runID)|\(roundIndex)"
            if let existing = preferredByRunKey[key] {
                if preferredSourceRank(for: sample.sourceKind) < preferredSourceRank(for: existing.sourceKind) {
                    preferredByRunKey[key] = sample
                }
            } else {
                preferredByRunKey[key] = sample
            }
        }

        let completedRunIDs = Set(
            passthrough.compactMap { sample -> String? in
                guard sample.metricKind == .firstResponse,
                      sample.sourceKind == "completed_run_turns",
                      let runID = sample.runID,
                      !runID.isEmpty else {
                    return nil
                }
                return runID
            }
        )
        let filteredPassthrough = passthrough.filter { sample in
            guard sample.metricKind == .firstResponse,
                  sample.sourceKind == "terminal_first_output",
                  let runID = sample.runID,
                  !runID.isEmpty else {
                return true
            }
            return !completedRunIDs.contains(runID)
        }

        return (filteredPassthrough + preferredByRunKey.values).sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp {
                return lhs.timestamp < rhs.timestamp
            }
            return lhs.id < rhs.id
        }
    }

    public static func isLatencyRelevantAPIEndpoint(
        provider: String,
        endpoint: String?
    ) -> Bool {
        guard let endpoint else { return false }
        let normalizedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedEndpoint.isEmpty else { return false }

        switch normalizedProvider {
        case "openai":
            return normalizedEndpoint == "/v1/responses" ||
                normalizedEndpoint == "/v1/chat/completions" ||
                normalizedEndpoint == "/v1/completions"
        case "anthropic":
            return normalizedEndpoint == "/v1/messages" ||
                normalizedEndpoint == "/v1/complete"
        case "gemini":
            return normalizedEndpoint.contains("generatecontent")
        default:
            return true
        }
    }

    public static func preferredAPILatencyMs(
        roundTripMs: Int?,
        timeToFirstTokenMs: Int?
    ) -> Int? {
        if let timeToFirstTokenMs, timeToFirstTokenMs > 0 {
            return timeToFirstTokenMs
        }
        if let roundTripMs, roundTripMs > 0 {
            return roundTripMs
        }
        return nil
    }

    public static func aggregate(samples: [ProviderLatencySample]) -> ProviderLatencyAggregate? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.map(\.latencyMs).sorted()
        let count = sorted.count
        let total = sorted.reduce(0, +)
        return ProviderLatencyAggregate(
            count: count,
            averageLatencyMs: Double(total) / Double(count),
            p50LatencyMs: percentile(sortedValues: sorted, percentile: 0.50),
            p95LatencyMs: percentile(sortedValues: sorted, percentile: 0.95),
            minLatencyMs: sorted.first,
            maxLatencyMs: sorted.last
        )
    }

    public static func bucketed(
        samples: [ProviderLatencySample],
        by bucketKind: ProviderLatencyBucketKind,
        calendar: Calendar = .current
    ) -> [ProviderLatencyBucketPoint] {
        bucketSamples(samples, by: bucketKind, calendar: calendar, timestamp: \.timestamp) { key, label, group in
            guard let aggregate = aggregate(samples: group) else { return nil }
            return ProviderLatencyBucketPoint(id: key, label: label, aggregate: aggregate)
        }
    }

    public static func activityBucketed(
        samples: [ProviderActivitySample],
        by bucketKind: ProviderLatencyBucketKind,
        calendar: Calendar = .current
    ) -> [ProviderActivityBucketPoint] {
        bucketSamples(samples, by: bucketKind, calendar: calendar, timestamp: \.timestamp) { key, label, group in
            ProviderActivityBucketPoint(id: key, label: label, count: group.count)
        }
    }

    /// Group `samples` by `bucketKey(for:timestamp:)`, sort by the
    /// `bucketMetadata` ordering value, and call `pointFromGroup` for
    /// each non-empty bucket. The two public bucket methods share this
    /// shape; only the per-group point construction differs.
    private static func bucketSamples<Sample, Point>(
        _ samples: [Sample],
        by bucketKind: ProviderLatencyBucketKind,
        calendar: Calendar,
        timestamp: (Sample) -> Date,
        pointFromGroup: (_ key: String, _ label: String, _ group: [Sample]) -> Point?
    ) -> [Point] {
        let grouped = Dictionary(grouping: samples) { sample in
            bucketKey(for: timestamp(sample), bucketKind: bucketKind, calendar: calendar)
        }

        let metadata = grouped.keys.compactMap { key -> (String, String, Int)? in
            bucketMetadata(for: key, bucketKind: bucketKind, calendar: calendar)
        }

        return metadata.sorted { $0.2 < $1.2 }.compactMap { key, label, _ in
            guard let group = grouped[key] else { return nil }
            return pointFromGroup(key, label, group)
        }
    }

    private static func bucketKey(
        for date: Date,
        bucketKind: ProviderLatencyBucketKind,
        calendar: Calendar
    ) -> String {
        switch bucketKind {
        case .day:
            let comps = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
        case .weekday:
            return "\(calendar.component(.weekday, from: date))"
        case .periodOfDay:
            let hour = calendar.component(.hour, from: date)
            return LatencyPeriodOfDay.forHour(hour).rawValue
        case .hourOfDay:
            return "\(calendar.component(.hour, from: date))"
        }
    }

    private static func bucketMetadata(
        for key: String,
        bucketKind: ProviderLatencyBucketKind,
        calendar: Calendar
    ) -> (key: String, label: String, sortOrder: Int)? {
        switch bucketKind {
        case .day:
            return (key, dayLabel(key), daySortOrder(key))
        case .weekday:
            guard let weekday = Int(key) else { return nil }
            return (key, weekdayLabel(weekday, calendar: calendar), weekdaySortOrder(weekday, calendar: calendar))
        case .periodOfDay:
            guard let period = LatencyPeriodOfDay(rawValue: key) else { return nil }
            return (key, period.displayName, LatencyPeriodOfDay.allCases.firstIndex(of: period) ?? 0)
        case .hourOfDay:
            guard let hour = Int(key) else { return nil }
            return (key, String(format: "%02d:00", hour), hour)
        }
    }

    private static func dayLabel(_ key: String) -> String {
        let parts = key.split(separator: "-")
        guard parts.count == 3 else { return key }
        return "\(parts[1])/\(parts[2])"
    }

    private static func daySortOrder(_ key: String) -> Int {
        Int(key.replacingOccurrences(of: "-", with: "")) ?? .max
    }

    private static func weekdayLabel(_ weekday: Int, calendar: Calendar) -> String {
        let symbols = calendar.shortWeekdaySymbols
        guard weekday >= 1, weekday <= symbols.count else { return "\(weekday)" }
        return symbols[weekday - 1]
    }

    private static func weekdaySortOrder(_ weekday: Int, calendar: Calendar) -> Int {
        let firstWeekday = calendar.firstWeekday
        return (weekday - firstWeekday + 7) % 7
    }

    public static func completedRunFirstResponseSamples(
        run: TelemetryRun,
        turns: [TelemetryTurn],
        sourceKind: String = "completed_run_turns"
    ) -> [ProviderLatencySample] {
        guard isAuthoritativeCompletedRunLatencySource(run.rawTranscriptRef) else {
            return []
        }

        let runEndedAt = run.endedAt
        let inRunWindow = turns.filter { turn in
            guard let timestamp = turn.timestamp, timestamp >= run.startedAt else { return false }
            if let runEndedAt {
                return timestamp <= runEndedAt
            }
            return true
        }.sorted { lhs, rhs in
            if lhs.turnIndex != rhs.turnIndex {
                return lhs.turnIndex < rhs.turnIndex
            }
            return (lhs.timestamp ?? .distantPast) < (rhs.timestamp ?? .distantPast)
        }

        var samples: [ProviderLatencySample] = []
        var pendingHuman: (index: Int, timestamp: Date)?
        var roundIndex = 0

        for turn in inRunWindow {
            guard let timestamp = turn.timestamp else { continue }
            switch turn.role {
            case .human:
                pendingHuman = (roundIndex, timestamp)
                roundIndex += 1
            case .assistant:
                let currentPendingHuman: (index: Int, timestamp: Date)
                if let pendingHuman {
                    currentPendingHuman = pendingHuman
                } else {
                    currentPendingHuman = (roundIndex, run.startedAt)
                    roundIndex += 1
                }
                guard timestamp >= currentPendingHuman.timestamp else { continue }
                let latencyMs = Int((timestamp.timeIntervalSince(currentPendingHuman.timestamp) * 1000).rounded())
                guard latencyMs >= 0 else { continue }
                samples.append(
                    ProviderLatencySample(
                        id: completedRunFirstResponseSampleID(
                            runID: run.id,
                            roundIndex: currentPendingHuman.index,
                            sourceKind: sourceKind
                        ),
                        provider: run.provider.lowercased(),
                        metricKind: .firstResponse,
                        latencyMs: latencyMs,
                        timestamp: timestamp,
                        model: run.model,
                        sessionID: run.sessionID,
                        runID: run.id,
                        roundIndex: currentPendingHuman.index,
                        projectPath: run.repoPath ?? run.cwd,
                        sourceKind: sourceKind
                    )
                )
                clearPendingHuman(&pendingHuman)
            default:
                continue
            }
        }

        return samples
    }

    public static func completedRunFirstResponseSample(
        run: TelemetryRun,
        turns: [TelemetryTurn],
        sourceKind: String = "completed_run_turns"
    ) -> ProviderLatencySample? {
        completedRunFirstResponseSamples(
            run: run,
            turns: turns,
            sourceKind: sourceKind
        ).first
    }

    public static func completedRunFirstResponseSampleID(
        runID: String,
        roundIndex: Int,
        sourceKind: String = "completed_run_turns"
    ) -> String {
        "latency|\(runID)|\(ProviderLatencyMetricKind.firstResponse.rawValue)|r\(roundIndex)|\(sourceKind)"
    }

    private static func isAuthoritativeCompletedRunLatencySource(_ rawTranscriptRef: String?) -> Bool {
        guard let rawTranscriptRef else {
            return false
        }
        let trimmedRawTranscriptRef = rawTranscriptRef.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRawTranscriptRef.isEmpty else { return false }
        if trimmedRawTranscriptRef == "pty_log" || trimmedRawTranscriptRef == "terminal_buffer" {
            return false
        }
        return true
    }

    private static func preferredSourceRank(for sourceKind: String) -> Int {
        switch sourceKind {
        case "completed_run_turns":
            return 0
        case "terminal_first_output":
            return 1
        default:
            return 2
        }
    }

    private static func percentile(sortedValues: [Int], percentile: Double) -> Int? {
        guard !sortedValues.isEmpty else { return nil }
        let clamped = max(0.0, min(1.0, percentile))
        let index = Int((Double(sortedValues.count - 1) * clamped).rounded(.toNearestOrEven))
        return sortedValues[index]
    }

    private static func clearPendingHuman(_ pendingHuman: inout (index: Int, timestamp: Date)?) {
        pendingHuman = nil
    }
}
