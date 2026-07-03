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

    private static let isoWithFractional = DateFormatters.iso8601

    private static let isoBasic = DateFormatters.iso8601NoFractional

    private var databasePath: String {
        RuntimeIsolation.appSupportDirectory(named: "Chau7")
            .appendingPathComponent("Proxy", isDirectory: true)
            .appendingPathComponent("analytics.db")
            .path
    }

    /// Persistent read-only connection, opened lazily on first query.
    /// Eliminates per-call sqlite3_open / sqlite3_close overhead.
    private var persistentDB: OpaquePointer?
    private let dbLock = NSLock()

    private init() {}

    deinit {
        if let db = persistentDB {
            sqlite3_close(db)
        }
    }

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

            let rows = withFilteredStatement(db: db, sql: sql, after: after, projectPath: projectPath) { stmt -> [String: ProxyProviderAnalytics] in
                var aggregated: [String: ProxyProviderAnalytics] = [:]
                while stmt.step() == .row {
                    guard let rawProvider = stmt.columnText(0),
                          AnalyticsProvider.matches(rawProvider, filterKey: providerFilterKey),
                          let provider = AnalyticsProvider.key(for: rawProvider) else {
                        continue
                    }

                    let callCount = Int(stmt.columnInt64(1))
                    let current = aggregated[provider]
                    let mergedCallCount = (current?.callCount ?? 0) + callCount
                    let weightedLatency = (current?.averageLatencyMs ?? 0) * Double(current?.callCount ?? 0)
                        + stmt.columnDouble(8) * Double(callCount)

                    aggregated[provider] = ProxyProviderAnalytics(
                        provider: provider,
                        callCount: mergedCallCount,
                        totalInputTokens: (current?.totalInputTokens ?? 0) + Int(stmt.columnInt64(2)),
                        totalOutputTokens: (current?.totalOutputTokens ?? 0) + Int(stmt.columnInt64(3)),
                        totalCacheCreationTokens: (current?.totalCacheCreationTokens ?? 0) + Int(stmt.columnInt64(4)),
                        totalCacheReadTokens: (current?.totalCacheReadTokens ?? 0) + Int(stmt.columnInt64(5)),
                        totalReasoningTokens: (current?.totalReasoningTokens ?? 0) + Int(stmt.columnInt64(6)),
                        totalCostUSD: (current?.totalCostUSD ?? 0) + stmt.columnDouble(7),
                        averageLatencyMs: mergedCallCount > 0 ? weightedLatency / Double(mergedCallCount) : 0
                    )
                }
                return aggregated
            }
            guard let aggregated = rows else { return [] }
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

    func latencySamples(
        after: Date? = nil,
        providerFilterKey: String? = nil,
        projectPath: String? = nil
    ) -> [ProviderLatencySample] {
        withDatabase { db in
            var sql = """
            SELECT provider,
                   model,
                   endpoint,
                   latency_ms,
                   ttft_ms,
                   timestamp,
                   project_path,
                   session_id
            FROM api_calls
            """
            var clauses = [
                "(ttft_ms IS NOT NULL AND ttft_ms > 0) OR (latency_ms IS NOT NULL AND latency_ms > 0)",
                "status_code >= 200",
                "status_code < 300"
            ]
            if after != nil {
                clauses.append("timestamp >= ?")
            }
            if let projectPath, !projectPath.isEmpty {
                clauses.append("project_path = ?")
            }
            sql += " WHERE " + clauses.joined(separator: " AND ")
            sql += " ORDER BY timestamp ASC"

            return withFilteredStatement(db: db, sql: sql, after: after, projectPath: projectPath) { stmt -> [ProviderLatencySample] in
                var samples: [ProviderLatencySample] = []
                while stmt.step() == .row {
                    guard let rawProvider = stmt.columnText(0),
                          AnalyticsProvider.matches(rawProvider, filterKey: providerFilterKey),
                          let provider = AnalyticsProvider.key(for: rawProvider),
                          ProviderLatencyAnalytics.isLatencyRelevantAPIEndpoint(
                              provider: provider,
                              endpoint: stmt.columnText(2)
                          ),
                          let timestamp = stmt.columnText(5).flatMap(isoDate),
                          let latencyMs = ProviderLatencyAnalytics.preferredAPILatencyMs(
                              roundTripMs: Int(stmt.columnInt64(3)),
                              timeToFirstTokenMs: Int(stmt.columnInt64(4))
                          ) else {
                        continue
                    }

                    samples.append(
                        ProviderLatencySample(
                            provider: provider,
                            metricKind: .apiRequest,
                            latencyMs: latencyMs,
                            timestamp: timestamp,
                            model: stmt.columnText(1),
                            sessionID: stmt.columnText(7),
                            projectPath: stmt.columnText(6),
                            sourceKind: Int(stmt.columnInt64(4)) > 0 ? "proxy_api_ttft" : "proxy_api_round_trip"
                        )
                    )
                }
                return samples
            } ?? []
        } ?? []
    }

    func activitySamples(
        after: Date? = nil,
        providerFilterKey: String? = nil,
        projectPath: String? = nil
    ) -> [ProviderActivitySample] {
        withDatabase { db in
            var sql = """
            SELECT provider,
                   endpoint,
                   timestamp
            FROM api_calls
            """
            var clauses = [
                "status_code >= 200",
                "status_code < 300"
            ]
            if after != nil {
                clauses.append("timestamp >= ?")
            }
            if let projectPath, !projectPath.isEmpty {
                clauses.append("project_path = ?")
            }
            sql += " WHERE " + clauses.joined(separator: " AND ")
            sql += " ORDER BY timestamp ASC"

            return withFilteredStatement(db: db, sql: sql, after: after, projectPath: projectPath) { stmt -> [ProviderActivitySample] in
                var samples: [ProviderActivitySample] = []
                while stmt.step() == .row {
                    guard let rawProvider = stmt.columnText(0),
                          AnalyticsProvider.matches(rawProvider, filterKey: providerFilterKey),
                          let provider = AnalyticsProvider.key(for: rawProvider),
                          ProviderLatencyAnalytics.isLatencyRelevantAPIEndpoint(
                              provider: provider,
                              endpoint: stmt.columnText(1)
                          ),
                          let timestamp = stmt.columnText(2).flatMap(isoDate) else {
                        continue
                    }

                    samples.append(
                        ProviderActivitySample(
                            provider: provider,
                            timestamp: timestamp,
                            sourceKind: "proxy_api_call"
                        )
                    )
                }

                return samples
            } ?? []
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
            return SQLiteStatement.withStatement(db, sql) { stmt -> [ProxyDailyAnalyticsPoint] in
                if let projectPath, !projectPath.isEmpty {
                    stmt.bindText(1, projectPath)
                }

                var aggregated: [String: ProxyDailyAnalyticsPoint] = [:]
                while stmt.step() == .row {
                    guard let date = stmt.columnText(0) else { continue }
                    let rawProvider = stmt.columnText(1)
                    guard AnalyticsProvider.matches(rawProvider, filterKey: providerFilterKey) else { continue }
                    let current = aggregated[date]
                    aggregated[date] = ProxyDailyAnalyticsPoint(
                        date: date,
                        callCount: (current?.callCount ?? 0) + Int(stmt.columnInt64(2)),
                        totalTokens: (current?.totalTokens ?? 0) + Int(stmt.columnInt64(3)),
                        totalCostUSD: (current?.totalCostUSD ?? 0) + stmt.columnDouble(4)
                    )
                }
                return aggregated.keys.sorted().compactMap { aggregated[$0] }
            } ?? []
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
            return SQLiteStatement.withStatement(db, sql) { stmt -> [ProxyHourlyAnalyticsPoint] in
                if let projectPath, !projectPath.isEmpty {
                    stmt.bindText(1, projectPath)
                }

                var aggregated: [String: ProxyHourlyAnalyticsPoint] = [:]
                while stmt.step() == .row {
                    guard let hour = stmt.columnText(0) else { continue }
                    let rawProvider = stmt.columnText(1)
                    guard AnalyticsProvider.matches(rawProvider, filterKey: providerFilterKey) else { continue }
                    let current = aggregated[hour]
                    aggregated[hour] = ProxyHourlyAnalyticsPoint(
                        hour: hour,
                        callCount: (current?.callCount ?? 0) + Int(stmt.columnInt64(2)),
                        totalTokens: (current?.totalTokens ?? 0) + Int(stmt.columnInt64(3)),
                        totalCostUSD: (current?.totalCostUSD ?? 0) + stmt.columnDouble(4)
                    )
                }
                return aggregated.keys.sorted().compactMap { aggregated[$0] }
            } ?? []
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
            return SQLiteStatement.withStatement(db, sql) { stmt -> [APICallEvent] in
                var bindIndex: Int32 = 1
                if let projectPath, !projectPath.isEmpty {
                    stmt.bindText(bindIndex, projectPath)
                    bindIndex += 1
                }
                stmt.bindInt64(bindIndex, Int64(limit))

                var events: [APICallEvent] = []
                while stmt.step() == .row {
                    let rawProvider = stmt.columnText(1)
                    guard AnalyticsProvider.matches(rawProvider, filterKey: providerFilterKey) else { continue }
                    let timestamp = stmt.columnText(12).flatMap(isoDate) ?? Date.distantPast
                    events.append(
                        APICallEvent(
                            sessionId: stmt.columnText(0) ?? "",
                            provider: APICallEvent.Provider(rawValue: rawProvider ?? "") ?? .unknown,
                            model: stmt.columnText(2) ?? "",
                            endpoint: stmt.columnText(3) ?? "",
                            inputTokens: Int(stmt.columnInt64(4)),
                            outputTokens: Int(stmt.columnInt64(5)),
                            cacheCreationInputTokens: Int(stmt.columnInt64(6)),
                            cacheReadInputTokens: Int(stmt.columnInt64(7)),
                            reasoningOutputTokens: Int(stmt.columnInt64(8)),
                            latencyMs: Int(stmt.columnInt64(9)),
                            statusCode: Int(stmt.columnInt64(10)),
                            costUSD: stmt.columnDouble(11),
                            timestamp: timestamp,
                            errorMessage: stmt.columnText(13),
                            projectPath: stmt.columnText(14)
                        )
                    )
                }
                return events
            } ?? []
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

            let rows = withFilteredStatement(db: db, sql: sql, after: after, projectPath: projectPath) { stmt -> [String: ProxyModelAnalytics] in
                var aggregated: [String: ProxyModelAnalytics] = [:]
                while stmt.step() == .row {
                    guard let rawProvider = stmt.columnText(0),
                          AnalyticsProvider.matches(rawProvider, filterKey: providerFilterKey),
                          let provider = AnalyticsProvider.key(for: rawProvider) else {
                        continue
                    }

                    let model = stmt.columnText(1) ?? ""
                    let key = "\(provider)|\(model)"
                    let callCount = Int(stmt.columnInt64(2))
                    let current = aggregated[key]
                    let mergedCallCount = (current?.callCount ?? 0) + callCount
                    let weightedLatency = (current?.averageLatencyMs ?? 0) * Double(current?.callCount ?? 0)
                        + stmt.columnDouble(9) * Double(callCount)

                    aggregated[key] = ProxyModelAnalytics(
                        provider: provider,
                        model: model,
                        callCount: mergedCallCount,
                        totalInputTokens: (current?.totalInputTokens ?? 0) + Int(stmt.columnInt64(3)),
                        totalOutputTokens: (current?.totalOutputTokens ?? 0) + Int(stmt.columnInt64(4)),
                        totalCacheCreationTokens: (current?.totalCacheCreationTokens ?? 0) + Int(stmt.columnInt64(5)),
                        totalCacheReadTokens: (current?.totalCacheReadTokens ?? 0) + Int(stmt.columnInt64(6)),
                        totalReasoningTokens: (current?.totalReasoningTokens ?? 0) + Int(stmt.columnInt64(7)),
                        totalCostUSD: (current?.totalCostUSD ?? 0) + stmt.columnDouble(8),
                        averageLatencyMs: mergedCallCount > 0 ? weightedLatency / Double(mergedCallCount) : 0
                    )
                }
                return aggregated
            }
            guard let aggregated = rows else { return [] }
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

            return withFilteredStatement(db: db, sql: sql, after: after, projectPath: projectPath) { stmt -> Double in
                var totalErrors = 0
                var totalCalls = 0
                while stmt.step() == .row {
                    let rawProvider = stmt.columnText(0)
                    guard AnalyticsProvider.matches(rawProvider, filterKey: providerFilterKey) else { continue }
                    totalErrors += Int(stmt.columnInt64(1))
                    totalCalls += Int(stmt.columnInt64(2))
                }
                guard totalCalls > 0 else { return 0 }
                return Double(totalErrors) / Double(totalCalls)
            } ?? 0
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
        dbLock.lock()
        defer { dbLock.unlock() }

        if let db = persistentDB {
            return body(db)
        }

        let path = databasePath
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            Log.warn("ProxyAnalyticsStore: failed to open database at \(path)")
            return nil
        }
        persistentDB = db
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

    /// Prepares `sql`, binds the shared `after`/`projectPath` filter
    /// parameters (in that order, matching `appendCommonFilters`), and runs
    /// `body`. Returns nil when the prepare fails.
    private func withFilteredStatement<T>(
        db: OpaquePointer,
        sql: String,
        after: Date?,
        projectPath: String?,
        _ body: (SQLiteStatement) -> T
    ) -> T? {
        SQLiteStatement.withStatement(db, sql) { stmt in
            var bindIndex: Int32 = 1
            if let after {
                stmt.bindText(bindIndex, isoString(after))
                bindIndex += 1
            }
            if let projectPath, !projectPath.isEmpty {
                stmt.bindText(bindIndex, projectPath)
            }
            return body(stmt)
        }
    }

    private func mostRecentCallTimestamp(after: Date?, providerFilterKey: String?, projectPath: String?) -> Date? {
        withDatabase { db in
            var sql = """
            SELECT provider, MAX(timestamp)
            FROM api_calls
            """
            appendCommonFilters(to: &sql, after: after, projectPath: projectPath)
            sql += " GROUP BY provider"

            return withFilteredStatement(db: db, sql: sql, after: after, projectPath: projectPath) { stmt -> Date? in
                var latest: Date?
                while stmt.step() == .row {
                    let rawProvider = stmt.columnText(0)
                    guard AnalyticsProvider.matches(rawProvider, filterKey: providerFilterKey),
                          let value = stmt.columnText(1),
                          let date = isoDate(value) else {
                        continue
                    }
                    latest = max(latest ?? date, date)
                }
                return latest
            }.flatMap { $0 }
        }
    }

    private func isoString(_ date: Date) -> String {
        Self.isoWithFractional.string(from: date)
    }

    private func isoDate(_ value: String) -> Date? {
        Self.isoWithFractional.date(from: value) ?? Self.isoBasic.date(from: value)
    }
}
