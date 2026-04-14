import Foundation

public struct ProviderQuotaWindowSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let usedPercent: Double
    public let windowMinutes: Int?
    public let resetsAt: Date?

    public init(
        id: String,
        usedPercent: Double,
        windowMinutes: Int? = nil,
        resetsAt: Date? = nil
    ) {
        self.id = id
        self.usedPercent = min(max(usedPercent, 0), 100)
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
    }

    public var remainingPercent: Double {
        max(0, 100 - usedPercent)
    }

    public var canonicalWindowKey: String {
        if let windowMinutes {
            return "\(windowMinutes)m"
        }
        return id.lowercased()
    }
}

public struct ProviderQuotaSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let provider: String
    public let capturedAt: Date
    public let source: String
    public let planType: String?
    public let credits: Double?
    public let rawSourceRef: String?
    public let windows: [ProviderQuotaWindowSnapshot]

    public init(
        provider: String,
        capturedAt: Date,
        source: String,
        planType: String? = nil,
        credits: Double? = nil,
        rawSourceRef: String? = nil,
        windows: [ProviderQuotaWindowSnapshot]
    ) {
        self.provider = provider
        self.capturedAt = capturedAt
        self.source = source
        self.planType = planType
        self.credits = credits
        self.rawSourceRef = rawSourceRef
        self.windows = windows.sorted {
            ($0.windowMinutes ?? .max, $0.id) < ($1.windowMinutes ?? .max, $1.id)
        }
        self.id = "\(provider.lowercased())|\(Int(capturedAt.timeIntervalSince1970))|\(source)"
    }
}

public struct ProviderQuotaWindowMetrics: Equatable, Sendable {
    public let window: ProviderQuotaWindowSnapshot
    public let recentBurnPercentPerMinute: Double?
    public let sustainablePercentPerMinute: Double?
    public let remainingMinutes: Double?
    public let isUnsustainable: Bool

    public init(
        window: ProviderQuotaWindowSnapshot,
        recentBurnPercentPerMinute: Double?,
        sustainablePercentPerMinute: Double?,
        remainingMinutes: Double?,
        isUnsustainable: Bool
    ) {
        self.window = window
        self.recentBurnPercentPerMinute = recentBurnPercentPerMinute
        self.sustainablePercentPerMinute = sustainablePercentPerMinute
        self.remainingMinutes = remainingMinutes
        self.isUnsustainable = isUnsustainable
    }
}

public enum QuotaWarningKind: String, Codable, CaseIterable, Sendable {
    case unsustainablePace
    case remaining20
    case remaining10
    case remaining5
}

public struct ProviderQuotaWarning: Equatable, Sendable, Identifiable {
    public let provider: String
    public let window: ProviderQuotaWindowSnapshot
    public let kind: QuotaWarningKind

    public init(
        provider: String,
        window: ProviderQuotaWindowSnapshot,
        kind: QuotaWarningKind
    ) {
        self.provider = provider
        self.window = window
        self.kind = kind
    }

    public var id: String {
        let resetComponent = window.resetsAt.map { String(Int($0.timeIntervalSince1970)) } ?? "no-reset"
        return "\(provider.lowercased())|\(window.canonicalWindowKey)|\(kind.rawValue)|\(resetComponent)"
    }
}

public enum ProviderQuotaEvaluator {
    public static func metrics(
        for latest: ProviderQuotaSnapshot,
        recentSnapshots: [ProviderQuotaSnapshot],
        now: Date = Date()
    ) -> [ProviderQuotaWindowMetrics] {
        latest.windows.compactMap { window in
            metrics(
                provider: latest.provider,
                window: window,
                snapshots: recentSnapshots,
                now: now
            )
        }
    }

    public static func warnings(
        for latest: ProviderQuotaSnapshot,
        recentSnapshots: [ProviderQuotaSnapshot],
        now: Date = Date(),
        renewalGraceMinutes: Double = 10
    ) -> [ProviderQuotaWarning] {
        metrics(for: latest, recentSnapshots: recentSnapshots, now: now).compactMap { metrics in
            let remainingMinutes = metrics.remainingMinutes ?? .infinity
            guard remainingMinutes > renewalGraceMinutes else { return nil }

            if metrics.window.remainingPercent <= 5 {
                return ProviderQuotaWarning(provider: latest.provider, window: metrics.window, kind: .remaining5)
            }
            if metrics.window.remainingPercent <= 10 {
                return ProviderQuotaWarning(provider: latest.provider, window: metrics.window, kind: .remaining10)
            }
            if metrics.window.remainingPercent <= 20 {
                return ProviderQuotaWarning(provider: latest.provider, window: metrics.window, kind: .remaining20)
            }
            if metrics.isUnsustainable {
                return ProviderQuotaWarning(provider: latest.provider, window: metrics.window, kind: .unsustainablePace)
            }
            return nil
        }
    }

    private static func metrics(
        provider: String,
        window: ProviderQuotaWindowSnapshot,
        snapshots: [ProviderQuotaSnapshot],
        now: Date
    ) -> ProviderQuotaWindowMetrics? {
        let matchingSnapshots = snapshots
            .filter { $0.provider.caseInsensitiveCompare(provider) == .orderedSame }
            .compactMap { snapshot -> (Date, ProviderQuotaWindowSnapshot)? in
                guard let matchingWindow = snapshot.windows.first(where: { matches(window: $0, to: window) }) else {
                    return nil
                }
                if let latestResetAt = window.resetsAt,
                   let snapshotResetAt = matchingWindow.resetsAt,
                   abs(snapshotResetAt.timeIntervalSince(latestResetAt)) > 1 {
                    return nil
                }
                return (snapshot.capturedAt, matchingWindow)
            }
            .sorted { $0.0 < $1.0 }

        let latestPoint = matchingSnapshots.last
        let earliestPoint = matchingSnapshots.first

        let recentBurnPercentPerMinute: Double?
        if let earliestPoint, let latestPoint, latestPoint.0 > earliestPoint.0 {
            let elapsedMinutes = latestPoint.0.timeIntervalSince(earliestPoint.0) / 60
            let delta = latestPoint.1.usedPercent - earliestPoint.1.usedPercent
            recentBurnPercentPerMinute = elapsedMinutes > 0 ? max(0, delta / elapsedMinutes) : nil
        } else {
            recentBurnPercentPerMinute = nil
        }

        let remainingMinutes = window.resetsAt.map { max(0, $0.timeIntervalSince(now) / 60) }
        let sustainablePercentPerMinute: Double?
        if let remainingMinutes, remainingMinutes > 0 {
            sustainablePercentPerMinute = window.remainingPercent / remainingMinutes
        } else {
            sustainablePercentPerMinute = nil
        }

        let isUnsustainable: Bool
        if let recentBurnPercentPerMinute, let sustainablePercentPerMinute, sustainablePercentPerMinute > 0 {
            isUnsustainable = recentBurnPercentPerMinute > sustainablePercentPerMinute
        } else {
            isUnsustainable = false
        }

        return ProviderQuotaWindowMetrics(
            window: window,
            recentBurnPercentPerMinute: recentBurnPercentPerMinute,
            sustainablePercentPerMinute: sustainablePercentPerMinute,
            remainingMinutes: remainingMinutes,
            isUnsustainable: isUnsustainable
        )
    }

    private static func matches(window lhs: ProviderQuotaWindowSnapshot, to rhs: ProviderQuotaWindowSnapshot) -> Bool {
        if let lhsMinutes = lhs.windowMinutes, let rhsMinutes = rhs.windowMinutes {
            return lhsMinutes == rhsMinutes
        }
        return lhs.canonicalWindowKey == rhs.canonicalWindowKey
    }
}
