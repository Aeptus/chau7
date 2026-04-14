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
                latencySection
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

    private var latencySection: some View {
        GroupBox("AI Provider Latency") {
            VStack(alignment: .leading, spacing: 12) {
                if usageMonitor.latencyProviders.isEmpty {
                    Text("No latency samples captured yet.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 12) {
                        Picker("Range", selection: Binding(
                            get: { usageMonitor.selectedLatencyTimeRange },
                            set: { usageMonitor.selectedLatencyTimeRange = $0 }
                        )) {
                            ForEach(ProviderLatencyTimeRange.allCases) { range in
                                Text(range.rawValue).tag(range)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 120)

                        Picker("Provider", selection: Binding(
                            get: { usageMonitor.selectedLatencyProvider ?? usageMonitor.latencyProviders.first?.provider ?? "" },
                            set: { usageMonitor.selectLatencyProvider($0.isEmpty ? nil : $0) }
                        )) {
                            ForEach(usageMonitor.latencyProviders) { provider in
                                Text(provider.displayName).tag(provider.provider)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 160)

                        if let selectedProvider = usageMonitor.selectedLatencyProvider,
                           let selectedProviderOverview = usageMonitor.latencyProviders.first(where: { $0.provider == selectedProvider }),
                           selectedProviderOverview.metrics.count > 1 {
                            Picker("Metric", selection: Binding(
                                get: { usageMonitor.selectedLatencyMetricKind ?? selectedProviderOverview.metrics.first?.metricKind ?? .firstResponse },
                                set: { usageMonitor.selectLatencyMetricKind($0) }
                            )) {
                                ForEach(selectedProviderOverview.metrics) { metric in
                                    Text(metric.metricKind.displayName).tag(metric.metricKind)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                    }

                    if let dashboard = usageMonitor.latencyDashboard {
                        HStack(spacing: 16) {
                            latencyStat("Metric", dashboard.metricKind.displayName)
                            latencyStat("Samples", "\(dashboard.aggregate.count)")
                            latencyStat("Avg", latencyLabel(dashboard.aggregate.averageLatencyMs))
                            latencyStat("P50", dashboard.aggregate.p50LatencyMs.map { "\($0)ms" } ?? "n/a")
                            latencyStat("P95", dashboard.aggregate.p95LatencyMs.map { "\($0)ms" } ?? "n/a")
                        }

                        latencyBucketsChart("Per Day", buckets: dashboard.dailyBuckets)
                        latencyBucketsChart("Weekday", buckets: dashboard.weekdayBuckets)
                        latencyBucketsChart("Period of Day", buckets: dashboard.periodBuckets)
                        latencyBucketsChart("Hour of Day", buckets: dashboard.hourBuckets)
                    }
                }
            }
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

    private func latencyStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, design: .monospaced).bold())
        }
    }

    private func latencyBucketsChart(_ title: String, buckets: [ProviderLatencyBucketPoint]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))

            if buckets.isEmpty {
                Text("No data")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                GeometryReader { geo in
                    let maxValue = max(buckets.map { $0.aggregate.averageLatencyMs }.max() ?? 1, 1)
                    let barArea = geo.size.height - 28
                    let barWidth: CGFloat = 20
                    let spacing: CGFloat = 8
                    let contentWidth = max(
                        geo.size.width,
                        CGFloat(buckets.count) * barWidth + CGFloat(max(buckets.count - 1, 0)) * spacing
                    )

                    ScrollView(.horizontal, showsIndicators: buckets.count > 12) {
                        HStack(alignment: .bottom, spacing: spacing) {
                            ForEach(buckets) { bucket in
                                VStack(spacing: 2) {
                                    Text(latencyLabel(bucket.aggregate.averageLatencyMs))
                                        .font(.system(size: 8, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)

                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.accentColor.opacity(0.65))
                                        .frame(
                                            width: barWidth,
                                            height: max(2, barArea * CGFloat(bucket.aggregate.averageLatencyMs) / CGFloat(maxValue))
                                        )

                                    Text(bucket.label)
                                        .font(.system(size: 8))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                                .frame(width: barWidth + 6)
                                .help(
                                    "\(bucket.aggregate.count) samples, p50 \(bucket.aggregate.p50LatencyMs.map { "\($0)ms" } ?? "n/a"), p95 \(bucket.aggregate.p95LatencyMs.map { "\($0)ms" } ?? "n/a")"
                                )
                            }
                        }
                        .frame(width: contentWidth, alignment: .leading)
                    }
                }
                .frame(height: 120)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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

    private func latencyLabel(_ latencyMs: Double) -> String {
        if latencyMs >= 1000 {
            return String(format: "%.1fs", latencyMs / 1000)
        }
        return String(format: "%.0fms", latencyMs)
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
