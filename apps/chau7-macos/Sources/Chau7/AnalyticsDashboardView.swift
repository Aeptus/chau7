import SwiftUI
import Chau7Core

// MARK: - Analytics Dashboard View

/// Dashboard view showing terminal usage analytics.
/// Displays command frequency, timing, error rates, and AI API usage.
struct AnalyticsDashboardView: View {
    @ObservedObject var analytics = TerminalAnalytics.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                Text(L("Terminal Analytics", "Terminal Analytics"))
                    .font(.title2.bold())

                // Summary cards row
                HStack(spacing: 16) {
                    StatCard(title: L("analytics.commands", "Commands"), value: analytics.totalCommands.formatted(), icon: "terminal")
                    StatCard(title: L("analytics.successRate", "Success Rate"), value: analytics.successRateString, icon: "checkmark.circle")
                    StatCard(title: L("analytics.avgDuration", "Avg Duration"), value: analytics.avgDurationString, icon: "clock")
                    StatCard(title: L("analytics.activeTime", "Active Time"), value: analytics.activeTimeString, icon: "timer")
                }

                // Most used commands
                GroupBox(L("Most Used Commands", "Most Used Commands")) {
                    ForEach(analytics.topCommands.prefix(10), id: \.command) { cmd in
                        HStack {
                            Text(cmd.command)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                            Spacer()
                            Text(cmd.count.formatted())
                                .foregroundColor(.secondary)
                            Rectangle()
                                .fill(Color.accentColor.opacity(0.3))
                                .frame(width: barWidth(for: cmd.count), height: 16)
                                .cornerRadius(3)
                        }
                    }
                }

                // Error rate over time
                GroupBox(L("Error Rate (Last 7 Days)", "Error Rate (Last 7 Days)")) {
                    HStack(alignment: .bottom, spacing: 4) {
                        ForEach(analytics.dailyStats, id: \.date) { day in
                            VStack {
                                Rectangle()
                                    .fill(day.errorRate > 0.2 ? Color.red : Color.green)
                                    .frame(width: 30, height: max(4, CGFloat(day.errorRate) * 100))
                                Text(day.dayLabel)
                                    .font(.caption2)
                            }
                        }
                    }
                    .frame(height: 120)
                }

                // Shell usage breakdown
                GroupBox(L("Shell Usage", "Shell Usage")) {
                    ForEach(analytics.shellBreakdown, id: \.shell) { item in
                        HStack {
                            Circle()
                                .fill(item.color)
                                .frame(width: 12, height: 12)
                            Text(item.shell)
                            Spacer()
                            Text(String(format: L("analytics.percentage", "%d%%"), item.percentage))
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // AI API usage (if proxy enabled)
                if analytics.hasAPIData {
                    GroupBox(L("AI API Usage", "AI API Usage")) {
                        HStack(spacing: 16) {
                            StatCard(title: L("analytics.apiCalls", "API Calls"), value: analytics.totalAPICalls.formatted(), icon: "network")
                            StatCard(title: L("analytics.tokensUsed", "Tokens Used"), value: analytics.totalTokensString, icon: "text.bubble")
                            StatCard(title: L("analytics.estimatedCost", "Est. Cost"), value: analytics.estimatedCostString, icon: "dollarsign.circle")
                        }
                    }
                }
            }
            .padding()
        }
    }

    private func barWidth(for count: Int) -> CGFloat {
        let maxCount = analytics.topCommands.first?.count ?? 1
        return CGFloat(count) / CGFloat(max(maxCount, 1)) * 150
    }
}

// MARK: - Stat Card

/// A summary card displaying a single statistic with an icon.
struct StatCard: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.accentColor)
            Text(value)
                .font(.title3.bold())
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
