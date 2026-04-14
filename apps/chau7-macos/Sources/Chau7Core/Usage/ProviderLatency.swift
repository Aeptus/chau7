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
            return "API Request"
        case .firstResponse:
            return "First Response"
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

public enum ProviderLatencyAnalytics {
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
        let grouped = Dictionary(grouping: samples) { sample in
            bucketKey(for: sample.timestamp, bucketKind: bucketKind, calendar: calendar)
        }

        let metadata = grouped.keys.compactMap { key -> (String, String, Int)? in
            bucketMetadata(for: key, bucketKind: bucketKind, calendar: calendar)
        }

        return metadata.sorted { $0.2 < $1.2 }.compactMap { key, label, _ in
            guard let group = grouped[key], let aggregate = aggregate(samples: group) else { return nil }
            return ProviderLatencyBucketPoint(id: key, label: label, aggregate: aggregate)
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

    private static func percentile(sortedValues: [Int], percentile: Double) -> Int? {
        guard !sortedValues.isEmpty else { return nil }
        let clamped = max(0.0, min(1.0, percentile))
        let index = Int((Double(sortedValues.count - 1) * clamped).rounded(.toNearestOrEven))
        return sortedValues[index]
    }
}
