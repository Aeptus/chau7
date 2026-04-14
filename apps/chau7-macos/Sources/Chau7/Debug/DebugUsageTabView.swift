import SwiftUI
import Chau7Core

struct DebugUsageTabView: View {
    @Bindable private var settings = FeatureSettings.shared
    @Bindable private var usageMonitor = UsageMonitor.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                controlsSection
                ForEach(usageMonitor.providerSummaries) { summary in
                    providerSection(summary)
                }
                if let lastErrorMessage = usageMonitor.lastErrorMessage, !lastErrorMessage.isEmpty {
                    GroupBox("Errors") {
                        Text(lastErrorMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding()
        }
        .onAppear {
            usageMonitor.refreshNow()
        }
    }

    private var controlsSection: some View {
        GroupBox("Usage Monitoring") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Enable usage/quota capture", isOn: $settings.isUsageMonitoringEnabled)
                Toggle("Warn on unsustainable burn and 20/10/5% remaining", isOn: $settings.isUsageQuotaWarningsEnabled)

                HStack {
                    Text("Claude statusLine capture")
                        .font(.system(size: 12))
                    Spacer()
                    Text(usageMonitor.isClaudeStatusLineInstalled ? "Installed" : "Not installed")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Button("Refresh") {
                        usageMonitor.refreshNow()
                    }
                    .disabled(usageMonitor.isRefreshing)

                    if usageMonitor.isClaudeStatusLineInstalled {
                        Button("Remove Claude statusLine") {
                            usageMonitor.uninstallClaudeStatusLineCapture()
                        }
                    } else {
                        Button("Install Claude statusLine") {
                            usageMonitor.installClaudeStatusLineCapture()
                        }
                    }
                }

                if let lastRefreshAt = usageMonitor.lastRefreshAt {
                    Text("Last refresh: \(lastRefreshAt.formatted(date: .omitted, time: .standard))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func providerSection(_ summary: UsageProviderSummary) -> some View {
        GroupBox(summary.displayName) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let snapshot = summary.latestSnapshot {
                            Text("Source: \(snapshot.source)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            if let planType = snapshot.planType, !planType.isEmpty {
                                Text("Plan: \(planType)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Text("Captured: \(snapshot.capturedAt.formatted(date: .omitted, time: .standard))")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        } else if let statusMessage = summary.statusMessage {
                            Text(statusMessage)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if !summary.activeWarnings.isEmpty {
                        VStack(alignment: .trailing, spacing: 4) {
                            ForEach(summary.activeWarnings, id: \.id) { warning in
                                Text(label(for: warning.kind))
                                    .font(.system(size: 10, weight: .semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.orange.opacity(0.16))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }

                if let recent = summary.recentRunConsumption {
                    HStack(spacing: 16) {
                        stat("Recent Runs", "\(recent.runCount)")
                        stat("10m Tokens", compactTokens(recent.totalBillableTokens))
                        stat("10m Cost", currency(recent.totalCostUSD))
                    }
                }

                if summary.windowMetrics.isEmpty {
                    Text("No active quota windows captured yet.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(summary.windowMetrics, id: \.window.id) { metrics in
                            quotaWindowView(metrics)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func quotaWindowView(_ metrics: ProviderQuotaWindowMetrics) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(windowLabel(metrics.window))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(Int(metrics.window.remainingPercent.rounded()))% remaining")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(metrics.window.remainingPercent <= 10 ? .orange : .secondary)
            }

            ProgressView(value: metrics.window.usedPercent, total: 100)
                .tint(metrics.window.remainingPercent <= 10 ? .orange : .accentColor)

            HStack(spacing: 16) {
                stat("Used", "\(Int(metrics.window.usedPercent.rounded()))%")
                if let remainingMinutes = metrics.remainingMinutes {
                    stat("Reset In", minutesLabel(remainingMinutes))
                }
                if let recentBurn = metrics.recentBurnPercentPerMinute {
                    stat("10m Burn", paceLabel(recentBurn))
                }
                if let sustainable = metrics.sustainablePercentPerMinute {
                    stat("Sustainable", paceLabel(sustainable))
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
        }
    }

    private func currency(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    private func compactTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        }
        if count >= 1000 {
            return String(format: "%.1fK", Double(count) / 1000)
        }
        return "\(count)"
    }

    private func paceLabel(_ percentPerMinute: Double) -> String {
        String(format: "%.2f%%/m", percentPerMinute)
    }

    private func minutesLabel(_ remainingMinutes: Double) -> String {
        if remainingMinutes >= 120 {
            return String(format: "%.1fh", remainingMinutes / 60)
        }
        return "\(Int(remainingMinutes.rounded()))m"
    }

    private func windowLabel(_ window: ProviderQuotaWindowSnapshot) -> String {
        switch window.windowMinutes {
        case 300:
            return "5 Hour"
        case 10080:
            return "7 Day"
        case let minutes?:
            if minutes.isMultiple(of: 60) {
                return "\(minutes / 60) Hour"
            }
            return "\(minutes) Minute"
        default:
            return window.id
        }
    }

    private func label(for kind: QuotaWarningKind) -> String {
        switch kind {
        case .unsustainablePace:
            return "Unsustainable Pace"
        case .remaining20:
            return "20% Remaining"
        case .remaining10:
            return "10% Remaining"
        case .remaining5:
            return "5% Remaining"
        }
    }
}
