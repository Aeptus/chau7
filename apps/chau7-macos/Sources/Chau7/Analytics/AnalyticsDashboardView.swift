import SwiftUI
import Chau7Core

// MARK: - Time Range

enum AnalyticsTimeRange: String, CaseIterable, Identifiable {
    case today = "Today"
    case week = "7 Days"
    case twoWeeks = "14 Days"
    case month = "30 Days"
    case allTime = "All Time"

    var id: String {
        rawValue
    }

    var startDate: Date? {
        switch self {
        case .today: return Calendar.current.startOfDay(for: Date())
        case .week: return Calendar.current.date(byAdding: .day, value: -7, to: Date())
        case .twoWeeks: return Calendar.current.date(byAdding: .day, value: -14, to: Date())
        case .month: return Calendar.current.date(byAdding: .day, value: -30, to: Date())
        case .allTime: return nil
        }
    }

    var days: Int {
        switch self {
        case .today: return 1
        case .week: return 7
        case .twoWeeks: return 14
        case .month: return 30
        case .allTime: return 90
        }
    }
}

// MARK: - View Model

@MainActor
@Observable
final class APIAnalyticsDashboardModel {
    var selectedRange: AnalyticsTimeRange = .week
    var overallStats = APICallStats()
    var errorRate: Double = 0
    var providerStats: [ProxyProviderAnalytics] = []
    var modelStats: [ProxyModelAnalytics] = []
    var dailyTrend: [ProxyDailyAnalyticsPoint] = []
    var recentCalls: [APICallEvent] = []
    var isLoading = false

    @ObservationIgnored private var refreshTimer: DispatchSourceTimer?
    @ObservationIgnored private var notificationObserver: NSObjectProtocol?
    @ObservationIgnored private var lastRefreshDate = Date.distantPast

    func refresh() {
        let range = selectedRange
        let after = range.startDate
        let days = range.days

        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let store = ProxyAnalyticsStore.shared
            let stats = store.overallStats(after: after)
            let err = store.errorRate(after: after)
            let providers = store.providerStats(after: after)
            let models = store.modelStats(after: after)
            let trend = store.dailyTrend(days: days)
            let recent = store.recentCalls(limit: 30)

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                overallStats = stats
                errorRate = err
                providerStats = providers
                modelStats = models
                dailyTrend = trend
                recentCalls = recent
                isLoading = false
                lastRefreshDate = Date()
            }
        }
    }

    func startAutoRefresh() {
        refresh()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
        refreshTimer = timer

        notificationObserver = NotificationCenter.default.addObserver(
            forName: .apiCallRecorded,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, Date().timeIntervalSince(lastRefreshDate) > 2 else { return }
            refresh()
        }
    }

    func stopAutoRefresh() {
        refreshTimer?.cancel()
        refreshTimer = nil
        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
            notificationObserver = nil
        }
    }
}

// MARK: - Main Dashboard View

struct AnalyticsDashboardView: View {
    @State private var model = APIAnalyticsDashboardModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerRow
                kpiCards
                DailyTrendChart(data: model.dailyTrend)
                ProviderBreakdownView(providers: model.providerStats)
                ModelBreakdownTable(models: Array(model.modelStats.prefix(15)))
                RecentCallsTable(calls: model.recentCalls)
            }
            .padding()
        }
        .onAppear { model.startAutoRefresh() }
        .onDisappear { model.stopAutoRefresh() }
        .onChange(of: model.selectedRange) { _, _ in model.refresh() }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack {
            Text("API Analytics")
                .font(.title2.bold())
            Spacer()
            Picker("", selection: $model.selectedRange) {
                ForEach(AnalyticsTimeRange.allCases) { range in
                    Text(range.rawValue).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 340)
        }
    }

    // MARK: - KPI Cards

    private var kpiCards: some View {
        HStack(spacing: 12) {
            StatCard(
                title: "Total Cost",
                value: LocalizedFormatters.formatCostPrecise(model.overallStats.totalCost),
                icon: "dollarsign.circle"
            )
            StatCard(
                title: "Tokens",
                value: formatTokens(model.overallStats.totalInputTokens + model.overallStats.totalOutputTokens),
                icon: "number.circle"
            )
            StatCard(
                title: "API Calls",
                value: model.overallStats.callCount.formatted(),
                icon: "arrow.up.arrow.down.circle"
            )
            StatCard(
                title: "Avg Latency",
                value: String(format: "%.0fms", model.overallStats.averageLatencyMs),
                icon: "clock"
            )
            StatCard(
                title: "Error Rate",
                value: String(format: "%.1f%%", model.errorRate * 100),
                icon: "exclamationmark.triangle",
                tintColor: model.errorRate > 0.05 ? .red : nil
            )
        }
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1000 { return String(format: "%.1fK", Double(count) / 1000) }
        return "\(count)"
    }
}

// MARK: - Stat Card

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    var tintColor: Color?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(tintColor ?? .accentColor)
            Text(value)
                .font(.system(.title3, design: .monospaced).bold())
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
}
