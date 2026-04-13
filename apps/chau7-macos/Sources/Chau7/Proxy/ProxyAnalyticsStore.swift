import Foundation
import SQLite3
import Chau7Core

struct ProxyProviderAnalytics: Identifiable, Sendable {
    let provider: String
    let callCount: Int
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let totalCacheCreationTokens: Int
    let totalCacheReadTokens: Int
    let totalReasoningTokens: Int
    let totalCostUSD: Double
    let averageLatencyMs: Double

    var id: String {
        provider
    }

    var totalTokens: Int {
        totalInputTokens + totalOutputTokens
    }

    var totalBillableTokens: Int {
        totalInputTokens + totalCacheCreationTokens + totalCacheReadTokens + totalOutputTokens + totalReasoningTokens
    }
}

struct ProxyDailyAnalyticsPoint: Identifiable, Sendable {
    let date: String
    let callCount: Int
    let totalTokens: Int
    let totalCostUSD: Double

    var id: String {
        date
    }
}

struct ProxyHourlyAnalyticsPoint: Identifiable, Sendable {
    let hour: String
    let callCount: Int
    let totalTokens: Int
    let totalCostUSD: Double

    var id: String {
        hour
    }
}

struct ProxyModelAnalytics: Identifiable, Sendable {
    let provider: String
    let model: String
    let callCount: Int
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let totalCacheCreationTokens: Int
    let totalCacheReadTokens: Int
    let totalReasoningTokens: Int
    let totalCostUSD: Double
    let averageLatencyMs: Double

    var id: String {
        "\(provider)/\(model)"
    }

    var totalTokens: Int {
        totalInputTokens + totalOutputTokens
    }

    var totalBillableTokens: Int {
        totalInputTokens + totalCacheCreationTokens + totalCacheReadTokens + totalOutputTokens + totalReasoningTokens
    }
}

struct ProxyRepoAnalyticsSummary: Sendable {
    let callCount: Int
    let totalTokens: Int
    let totalCostUSD: Double
    let providers: [String]
    let lastCallAt: Date?
    let hourlyCost: [ProxyHourlyAnalyticsPoint]

    static let empty = ProxyRepoAnalyticsSummary(
        callCount: 0,
        totalTokens: 0,
        totalCostUSD: 0,
        providers: [],
        lastCallAt: nil,
        hourlyCost: []
    )
}

final class ProxyAnalyticsStore {
    static let shared = ProxyAnalyticsStore()

    private static let isoWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoBasic: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private var databasePath: String {
        RuntimeIsolation.appSupportDirectory(named: "Chau7")
            .appendingPathComponent("Proxy", isDirectory: true)
            .appendingPathComponent("analytics.db")
            .path
    }

    private init() {}

    func overallStats(after: Date? = nil, providerFilterKey: String? = nil, projectPath: String? = nil) -> APICallStats {
        let providers = providerStats(after: after, providerFilterKey: providerFilterKey, projectPath: projectPath)
        guard !providers.isEmpty else { return APICallStats() }

        let callCount = providers.reduce(0) { $0 + $1.callCount }
        let weightedLatency = providers.reduce(0.0) { partial, stat in
            partial + (stat.averageLatencyMs * Double(stat.callCount))
        }

        return APICallStats(
            callCount: callCount,
            totalInputTokens: providers.reduce(0) { $0 + $1.totalInputTokens },
            totalOutputTokens: providers.reduce(0) { $0 + $1.totalOutputTokens },
            totalCacheCreationTokens: providers.reduce(0) { $0 + $1.totalCacheCreationTokens },
            totalCacheReadTokens: providers.reduce(0) { $0 + $1.totalCacheReadTokens },
            totalReasoningTokens: providers.reduce(0) { $0 + $1.totalReasoningTokens },
            totalCost: providers.reduce(0.0) { $0 + $1.totalCostUSD },
            averageLatencyMs: callCount > 0 ? weightedLatency / Double(callCount) : 0
        )
    }

    func providerStats(after: Date? = nil, providerFilterKey: String? = nil, projectPath: String? = nil) -> [ProxyProviderAnalytics] {
        withDatabase { db in
            var sql = """
            SELECT provider,
                   COUNT(*),
                   COALESCE(SUM(input_tokens), 0),
                   COALESCE(SUM(output_tokens), 0),
                   COALESCE(SUM(cache_creation_input_tokens), 0),
                   COALESCE(SUM(cache_read_input_tokens), 0),
                   COALESCE(SUM(reasoning_output_tokens), 0),
                   COALESCE(SUM(cost_usd), 0),
                   COALESCE(AVG(latency_ms), 0)
            FROM api_calls
            """
            appendCommonFilters(to: &sql, after: after, projectPath: projectPath)
            sql += " GROUP BY provider ORDER BY COUNT(*) DESC, provider ASC"

            guard let stmt = prepareStatement(db: db, sql: sql, after: after, projectPath: projectPath) else { return [] }
            defer { sqlite3_finalize(stmt) }

            var aggregated: [String: ProxyProviderAnalytics] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let rawProvider = colText(stmt, 0),
                      AnalyticsProvider.matches(rawProvider, filterKey: providerFilterKey),
                      let provider = AnalyticsProvider.key(for: rawProvider) else {
                    continue
                }

                let callCount = Int(sqlite3_column_int64(stmt, 1))
                let current = aggregated[provider]
                let mergedCallCount = (current?.callCount ?? 0) + callCount
                let weightedLatency = (current?.averageLatencyMs ?? 0) * Double(current?.callCount ?? 0)
                    + sqlite3_column_double(stmt, 8) * Double(callCount)

                aggregated[provider] = ProxyProviderAnalytics(
                    provider: provider,
                    callCount: mergedCallCount,
                    totalInputTokens: (current?.totalInputTokens ?? 0) + Int(sqlite3_column_int64(stmt, 2)),
                    totalOutputTokens: (current?.totalOutputTokens ?? 0) + Int(sqlite3_column_int64(stmt, 3)),
                    totalCacheCreationTokens: (current?.totalCacheCreationTokens ?? 0) + Int(sqlite3_column_int64(stmt, 4)),
                    totalCacheReadTokens: (current?.totalCacheReadTokens ?? 0) + Int(sqlite3_column_int64(stmt, 5)),
                    totalReasoningTokens: (current?.totalReasoningTokens ?? 0) + Int(sqlite3_column_int64(stmt, 6)),
                    totalCostUSD: (current?.totalCostUSD ?? 0) + sqlite3_column_double(stmt, 7),
                    averageLatencyMs: mergedCallCount > 0 ? weightedLatency / Double(mergedCallCount) : 0
                )
            }
            return aggregated.values.sorted { lhs, rhs in
                if lhs.totalCostUSD != rhs.totalCostUSD {
                    return lhs.totalCostUSD > rhs.totalCostUSD
                }
                if lhs.callCount != rhs.callCount {
                    return lhs.callCount > rhs.callCount
                }
                return AnalyticsProvider.displayName(for: lhs.provider)
                    .localizedCaseInsensitiveCompare(AnalyticsProvider.displayName(for: rhs.provider)) == .orderedAscending
            }
        } ?? []
    }

    func dailyTrend(days: Int = 7, providerFilterKey: String? = nil, projectPath: String? = nil) -> [ProxyDailyAnalyticsPoint] {
        withDatabase { db in
            let clampedDays = max(1, min(days, 90))
            var sql = """
            SELECT date(datetime(timestamp, 'localtime')) AS day,
                   provider,
                   COUNT(*),
                   COALESCE(SUM(input_tokens), 0) + COALESCE(SUM(output_tokens), 0)
                     + COALESCE(SUM(cache_creation_input_tokens), 0)
                     + COALESCE(SUM(cache_read_input_tokens), 0)
                     + COALESCE(SUM(reasoning_output_tokens), 0),
                   COALESCE(SUM(cost_usd), 0)
            FROM api_calls
            WHERE timestamp >= datetime('now', 'localtime', '-\(clampedDays) days')
            """
            if let projectPath, !projectPath.isEmpty {
                sql += " AND project_path = ?"
            }
            sql += """
            GROUP BY day, provider
            ORDER BY day
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            if let projectPath, !projectPath.isEmpty {
                bindText(stmt, 1, projectPath)
            }

            var aggregated: [String: ProxyDailyAnalyticsPoint] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let date = colText(stmt, 0) else { continue }
                let rawProvider = colText(stmt, 1)
                guard AnalyticsProvider.matches(rawProvider, filterKey: providerFilterKey) else { continue }
                let current = aggregated[date]
                aggregated[date] = ProxyDailyAnalyticsPoint(
                    date: date,
                    callCount: (current?.callCount ?? 0) + Int(sqlite3_column_int64(stmt, 2)),
                    totalTokens: (current?.totalTokens ?? 0) + Int(sqlite3_column_int64(stmt, 3)),
                    totalCostUSD: (current?.totalCostUSD ?? 0) + sqlite3_column_double(stmt, 4)
                )
            }
            return aggregated.keys.sorted().compactMap { aggregated[$0] }
        } ?? []
    }

    func hourlyTrend(days: Int = 1, providerFilterKey: String? = nil, projectPath: String? = nil) -> [ProxyHourlyAnalyticsPoint] {
        withDatabase { db in
            let clampedDays = max(1, min(days, 90))
            var sql = """
            SELECT strftime('%Y-%m-%d %H:00', datetime(timestamp, 'localtime')) AS hour,
                   provider,
                   COUNT(*),
                   COALESCE(SUM(input_tokens), 0) + COALESCE(SUM(output_tokens), 0)
                     + COALESCE(SUM(cache_creation_input_tokens), 0)
                     + COALESCE(SUM(cache_read_input_tokens), 0)
                     + COALESCE(SUM(reasoning_output_tokens), 0),
                   COALESCE(SUM(cost_usd), 0)
            FROM api_calls
            WHERE timestamp >= datetime('now', 'localtime', '-\(clampedDays) days')
            """
            if let projectPath, !projectPath.isEmpty {
                sql += " AND project_path = ?"
            }
            sql += """
            GROUP BY hour, provider
            ORDER BY hour
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            if let projectPath, !projectPath.isEmpty {
                bindText(stmt, 1, projectPath)
            }

            var aggregated: [String: ProxyHourlyAnalyticsPoint] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let hour = colText(stmt, 0) else { continue }
                let rawProvider = colText(stmt, 1)
                guard AnalyticsProvider.matches(rawProvider, filterKey: providerFilterKey) else { continue }
                let current = aggregated[hour]
                aggregated[hour] = ProxyHourlyAnalyticsPoint(
                    hour: hour,
                    callCount: (current?.callCount ?? 0) + Int(sqlite3_column_int64(stmt, 2)),
                    totalTokens: (current?.totalTokens ?? 0) + Int(sqlite3_column_int64(stmt, 3)),
                    totalCostUSD: (current?.totalCostUSD ?? 0) + sqlite3_column_double(stmt, 4)
                )
            }
            return aggregated.keys.sorted().compactMap { aggregated[$0] }
        } ?? []
    }

    func recentCalls(limit: Int = 50, providerFilterKey: String? = nil, projectPath: String? = nil) -> [APICallEvent] {
        withDatabase { db in
            var sql = """
            SELECT session_id, provider, model, endpoint, input_tokens, output_tokens,
                   cache_creation_input_tokens, cache_read_input_tokens, reasoning_output_tokens,
                   latency_ms, status_code, cost_usd, timestamp, error_message, project_path
            FROM api_calls
            """
            appendCommonFilters(to: &sql, after: nil, projectPath: projectPath)
            sql += """
            ORDER BY timestamp DESC
            LIMIT ?
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            var bindIndex: Int32 = 1
            if let projectPath, !projectPath.isEmpty {
                bindText(stmt, bindIndex, projectPath)
                bindIndex += 1
            }
            sqlite3_bind_int64(stmt, bindIndex, Int64(limit))

            var events: [APICallEvent] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let rawProvider = colText(stmt, 1)
                guard AnalyticsProvider.matches(rawProvider, filterKey: providerFilterKey) else { continue }
                let timestamp = colText(stmt, 12).flatMap(isoDate) ?? Date.distantPast
                events.append(
                    APICallEvent(
                        sessionId: colText(stmt, 0) ?? "",
                        provider: APICallEvent.Provider(rawValue: rawProvider ?? "") ?? .unknown,
                        model: colText(stmt, 2) ?? "",
                        endpoint: colText(stmt, 3) ?? "",
                        inputTokens: Int(sqlite3_column_int64(stmt, 4)),
                        outputTokens: Int(sqlite3_column_int64(stmt, 5)),
                        cacheCreationInputTokens: Int(sqlite3_column_int64(stmt, 6)),
                        cacheReadInputTokens: Int(sqlite3_column_int64(stmt, 7)),
                        reasoningOutputTokens: Int(sqlite3_column_int64(stmt, 8)),
                        latencyMs: Int(sqlite3_column_int64(stmt, 9)),
                        statusCode: Int(sqlite3_column_int64(stmt, 10)),
                        costUSD: sqlite3_column_double(stmt, 11),
                        timestamp: timestamp,
                        errorMessage: colText(stmt, 13),
                        projectPath: colText(stmt, 14)
                    )
                )
            }
            return events
        } ?? []
    }

    func modelStats(after: Date? = nil, providerFilterKey: String? = nil, projectPath: String? = nil) -> [ProxyModelAnalytics] {
        withDatabase { db in
            var sql = """
            SELECT provider, model, COUNT(*),
                   COALESCE(SUM(input_tokens), 0),
                   COALESCE(SUM(output_tokens), 0),
                   COALESCE(SUM(cache_creation_input_tokens), 0),
                   COALESCE(SUM(cache_read_input_tokens), 0),
                   COALESCE(SUM(reasoning_output_tokens), 0),
                   COALESCE(SUM(cost_usd), 0),
                   COALESCE(AVG(latency_ms), 0)
            FROM api_calls
            """
            appendCommonFilters(to: &sql, after: after, projectPath: projectPath)
            sql += " GROUP BY provider, model ORDER BY SUM(cost_usd) DESC"

            guard let stmt = prepareStatement(db: db, sql: sql, after: after, projectPath: projectPath) else { return [] }
            defer { sqlite3_finalize(stmt) }

            var aggregated: [String: ProxyModelAnalytics] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let rawProvider = colText(stmt, 0),
                      AnalyticsProvider.matches(rawProvider, filterKey: providerFilterKey),
                      let provider = AnalyticsProvider.key(for: rawProvider) else {
                    continue
                }

                let model = colText(stmt, 1) ?? ""
                let key = "\(provider)|\(model)"
                let callCount = Int(sqlite3_column_int64(stmt, 2))
                let current = aggregated[key]
                let mergedCallCount = (current?.callCount ?? 0) + callCount
                let weightedLatency = (current?.averageLatencyMs ?? 0) * Double(current?.callCount ?? 0)
                    + sqlite3_column_double(stmt, 9) * Double(callCount)

                aggregated[key] = ProxyModelAnalytics(
                    provider: provider,
                    model: model,
                    callCount: mergedCallCount,
                    totalInputTokens: (current?.totalInputTokens ?? 0) + Int(sqlite3_column_int64(stmt, 3)),
                    totalOutputTokens: (current?.totalOutputTokens ?? 0) + Int(sqlite3_column_int64(stmt, 4)),
                    totalCacheCreationTokens: (current?.totalCacheCreationTokens ?? 0) + Int(sqlite3_column_int64(stmt, 5)),
                    totalCacheReadTokens: (current?.totalCacheReadTokens ?? 0) + Int(sqlite3_column_int64(stmt, 6)),
                    totalReasoningTokens: (current?.totalReasoningTokens ?? 0) + Int(sqlite3_column_int64(stmt, 7)),
                    totalCostUSD: (current?.totalCostUSD ?? 0) + sqlite3_column_double(stmt, 8),
                    averageLatencyMs: mergedCallCount > 0 ? weightedLatency / Double(mergedCallCount) : 0
                )
            }
            return aggregated.values.sorted { lhs, rhs in
                if lhs.totalCostUSD != rhs.totalCostUSD {
                    return lhs.totalCostUSD > rhs.totalCostUSD
                }
                if lhs.callCount != rhs.callCount {
                    return lhs.callCount > rhs.callCount
                }
                return lhs.model.localizedCaseInsensitiveCompare(rhs.model) == .orderedAscending
            }
        } ?? []
    }

    func errorRate(after: Date? = nil, providerFilterKey: String? = nil, projectPath: String? = nil) -> Double {
        withDatabase { db in
            var sql = """
            SELECT provider,
                   SUM(CASE WHEN status_code < 200 OR status_code >= 300 THEN 1 ELSE 0 END),
                   COUNT(*)
            FROM api_calls
            """
            appendCommonFilters(to: &sql, after: after, projectPath: projectPath)
            sql += " GROUP BY provider"

            guard let stmt = prepareStatement(db: db, sql: sql, after: after, projectPath: projectPath) else { return 0 }
            defer { sqlite3_finalize(stmt) }
            var totalErrors = 0
            var totalCalls = 0
            while sqlite3_step(stmt) == SQLITE_ROW {
                let rawProvider = colText(stmt, 0)
                guard AnalyticsProvider.matches(rawProvider, filterKey: providerFilterKey) else { continue }
                totalErrors += Int(sqlite3_column_int64(stmt, 1))
                totalCalls += Int(sqlite3_column_int64(stmt, 2))
            }
            guard totalCalls > 0 else { return 0 }
            return Double(totalErrors) / Double(totalCalls)
        } ?? 0
    }

    func repoSummary(projectPath: String, after: Date? = nil, providerFilterKey: String? = nil, hourlyDays: Int = 1) -> ProxyRepoAnalyticsSummary {
        let stats = overallStats(after: after, providerFilterKey: providerFilterKey, projectPath: projectPath)
        let providers = providerStats(after: after, providerFilterKey: providerFilterKey, projectPath: projectPath).map(\.provider)
        let hourlyCost = hourlyTrend(days: hourlyDays, providerFilterKey: providerFilterKey, projectPath: projectPath)
        let lastCallAt = mostRecentCallTimestamp(after: after, providerFilterKey: providerFilterKey, projectPath: projectPath)
        return ProxyRepoAnalyticsSummary(
            callCount: stats.callCount,
            totalTokens: stats.totalAllTokens,
            totalCostUSD: stats.totalCost,
            providers: providers,
            lastCallAt: lastCallAt,
            hourlyCost: hourlyCost
        )
    }

    private func withDatabase<T>(_ body: (OpaquePointer) -> T?) -> T? {
        let path = databasePath
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            Log.warn("ProxyAnalyticsStore: failed to open database at \(path)")
            return nil
        }
        defer { sqlite3_close(db) }
        return body(db)
    }

    private func appendCommonFilters(to sql: inout String, after: Date?, projectPath: String?) {
        var clauses: [String] = []
        if after != nil {
            clauses.append("timestamp >= ?")
        }
        if let projectPath, !projectPath.isEmpty {
            clauses.append("project_path = ?")
        }
        if !clauses.isEmpty {
            sql += " WHERE " + clauses.joined(separator: " AND ")
        }
    }

    private func prepareStatement(
        db: OpaquePointer,
        sql: String,
        after: Date?,
        projectPath: String?
    ) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        var bindIndex: Int32 = 1
        if let after {
            bindText(stmt, bindIndex, isoString(after))
            bindIndex += 1
        }
        if let projectPath, !projectPath.isEmpty {
            bindText(stmt, bindIndex, projectPath)
        }
        return stmt
    }

    private func mostRecentCallTimestamp(after: Date?, providerFilterKey: String?, projectPath: String?) -> Date? {
        withDatabase { db in
            var sql = """
            SELECT provider, MAX(timestamp)
            FROM api_calls
            """
            appendCommonFilters(to: &sql, after: after, projectPath: projectPath)
            sql += " GROUP BY provider"

            guard let stmt = prepareStatement(db: db, sql: sql, after: after, projectPath: projectPath) else { return nil }
            defer { sqlite3_finalize(stmt) }

            var latest: Date?
            while sqlite3_step(stmt) == SQLITE_ROW {
                let rawProvider = colText(stmt, 0)
                guard AnalyticsProvider.matches(rawProvider, filterKey: providerFilterKey),
                      let value = colText(stmt, 1),
                      let date = isoDate(value) else {
                    continue
                }
                if latest == nil || date > latest! {
                    latest = date
                }
            }
            return latest
        }
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, (value as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func colText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let text = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: text)
    }

    private func isoString(_ date: Date) -> String {
        Self.isoWithFractional.string(from: date)
    }

    private func isoDate(_ value: String) -> Date? {
        Self.isoWithFractional.date(from: value) ?? Self.isoBasic.date(from: value)
    }
}
