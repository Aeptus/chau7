import Foundation
import SQLite3
import Chau7Core

struct ProxyProviderAnalytics: Identifiable, Sendable {
    let provider: String
    let callCount: Int
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let totalCostUSD: Double
    let averageLatencyMs: Double

    var id: String {
        provider
    }

    var totalTokens: Int {
        totalInputTokens + totalOutputTokens
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

    func overallStats(after: Date? = nil) -> APICallStats {
        withDatabase { db in
            var sql = """
            SELECT COUNT(*),
                   COALESCE(SUM(input_tokens), 0),
                   COALESCE(SUM(output_tokens), 0),
                   COALESCE(SUM(cost_usd), 0),
                   COALESCE(AVG(latency_ms), 0)
            FROM api_calls
            """
            if after != nil {
                sql += " WHERE timestamp >= ?"
            }

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return APICallStats() }
            defer { sqlite3_finalize(stmt) }
            if let after {
                bindText(stmt, 1, isoString(after))
            }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return APICallStats() }
            return APICallStats(
                callCount: Int(sqlite3_column_int64(stmt, 0)),
                totalInputTokens: Int(sqlite3_column_int64(stmt, 1)),
                totalOutputTokens: Int(sqlite3_column_int64(stmt, 2)),
                totalCost: sqlite3_column_double(stmt, 3),
                averageLatencyMs: sqlite3_column_double(stmt, 4)
            )
        } ?? APICallStats()
    }

    func providerStats(after: Date? = nil) -> [ProxyProviderAnalytics] {
        withDatabase { db in
            var sql = """
            SELECT provider,
                   COUNT(*),
                   COALESCE(SUM(input_tokens), 0),
                   COALESCE(SUM(output_tokens), 0),
                   COALESCE(SUM(cost_usd), 0),
                   COALESCE(AVG(latency_ms), 0)
            FROM api_calls
            """
            if after != nil {
                sql += " WHERE timestamp >= ?"
            }
            sql += " GROUP BY provider ORDER BY COUNT(*) DESC, provider ASC"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            if let after {
                bindText(stmt, 1, isoString(after))
            }

            var results: [ProxyProviderAnalytics] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let provider = colText(stmt, 0) else { continue }
                results.append(
                    ProxyProviderAnalytics(
                        provider: provider,
                        callCount: Int(sqlite3_column_int64(stmt, 1)),
                        totalInputTokens: Int(sqlite3_column_int64(stmt, 2)),
                        totalOutputTokens: Int(sqlite3_column_int64(stmt, 3)),
                        totalCostUSD: sqlite3_column_double(stmt, 4),
                        averageLatencyMs: sqlite3_column_double(stmt, 5)
                    )
                )
            }
            return results
        } ?? []
    }

    func dailyTrend(days: Int = 7) -> [ProxyDailyAnalyticsPoint] {
        withDatabase { db in
            let clampedDays = max(1, min(days, 90))
            let sql = """
            SELECT date(timestamp) AS day,
                   COUNT(*),
                   COALESCE(SUM(input_tokens), 0) + COALESCE(SUM(output_tokens), 0),
                   COALESCE(SUM(cost_usd), 0)
            FROM api_calls
            WHERE timestamp >= date('now', '-\(clampedDays) days')
            GROUP BY day
            ORDER BY day
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            var results: [ProxyDailyAnalyticsPoint] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let date = colText(stmt, 0) else { continue }
                results.append(
                    ProxyDailyAnalyticsPoint(
                        date: date,
                        callCount: Int(sqlite3_column_int64(stmt, 1)),
                        totalTokens: Int(sqlite3_column_int64(stmt, 2)),
                        totalCostUSD: sqlite3_column_double(stmt, 3)
                    )
                )
            }
            return results
        } ?? []
    }

    func recentCalls(limit: Int = 50) -> [APICallEvent] {
        withDatabase { db in
            let sql = """
            SELECT session_id, provider, model, endpoint, input_tokens, output_tokens,
                   latency_ms, status_code, cost_usd, timestamp, error_message
            FROM api_calls
            ORDER BY timestamp DESC
            LIMIT ?
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(limit))

            var events: [APICallEvent] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let timestamp = colText(stmt, 9).flatMap(isoDate) ?? Date.distantPast
                events.append(
                    APICallEvent(
                        sessionId: colText(stmt, 0) ?? "",
                        provider: APICallEvent.Provider(rawValue: colText(stmt, 1) ?? "") ?? .unknown,
                        model: colText(stmt, 2) ?? "",
                        endpoint: colText(stmt, 3) ?? "",
                        inputTokens: Int(sqlite3_column_int64(stmt, 4)),
                        outputTokens: Int(sqlite3_column_int64(stmt, 5)),
                        latencyMs: Int(sqlite3_column_int64(stmt, 6)),
                        statusCode: Int(sqlite3_column_int64(stmt, 7)),
                        costUSD: sqlite3_column_double(stmt, 8),
                        timestamp: timestamp,
                        errorMessage: colText(stmt, 10)
                    )
                )
            }
            return events
        } ?? []
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
