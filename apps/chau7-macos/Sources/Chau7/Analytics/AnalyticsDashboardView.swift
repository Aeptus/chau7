import SwiftUI
import Chau7Core

// MARK: - Analytics Dashboard View

/// Dashboard view showing terminal usage analytics.
/// Displays command frequency, timing, error rates, and AI API usage.
struct AnalyticsDashboardView: View {
    var analytics = TerminalAnalytics.shared

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
