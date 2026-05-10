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
        GroupBox("AI Provider Usage") {
            VStack(alignment: .leading, spacing: 12) {
                if usageMonitor.latencyProviders.isEmpty {
                    Text("No provider activity captured yet.")
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
                    }

                    if let dashboard = usageMonitor.latencyDashboard {
                        VStack(alignment: .leading, spacing: 4) {
                            if !dashboard.metricKinds.isEmpty {
                                Text(comparableLatencyExplanation(for: dashboard.metricKinds))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            if dashboard.totalInteractionCount > 0 {
                                let coverage = Double(dashboard.sampledCount) / Double(dashboard.totalInteractionCount)
                                Text(
                                    "Coverage: \(dashboard.sampledCount) latency samples out of \(dashboard.totalInteractionCount) captured interactions (\(Int((coverage * 100).rounded()))%). Activity buckets below use all captured interactions; latency buckets use only the subset with valid latency evidence."
                                )
                                .font(.system(size: 10))
                                .foregroundStyle(
                                    coverage < 0.8
                                        ? AnyShapeStyle(.orange)
                                        : AnyShapeStyle(.tertiary)
                                )
                            }
                            Text("Latency buckets use P50 to show the typical experience. Activity buckets show total interaction counts by time bucket.")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }

                        if let aggregate = dashboard.aggregate {
                            HStack(spacing: 16) {
                                latencyStat("Latency", "Comparable")
                                latencyStat("Samples", "\(aggregate.count)")
                                latencyStat("P50", aggregate.p50LatencyMs.map { "\($0)ms" } ?? "n/a")
                                latencyStat("P95", aggregate.p95LatencyMs.map { "\($0)ms" } ?? "n/a")
                                latencyStat("Avg", latencyLabel(aggregate.averageLatencyMs))
                            }

                            Text("P50 is the median sample. P95 shows the slower tail. Avg is still shown, but it can be pulled up by long streaming requests and outliers.")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)

                            latencyBucketsChart("Latency Per Day", buckets: dashboard.dailyBuckets)
                            latencyBucketsChart("Latency by Weekday", buckets: dashboard.weekdayBuckets)
                            latencyBucketsChart("Latency by Period", buckets: dashboard.periodBuckets)
                            latencyBucketsChart("Latency by Hour", buckets: dashboard.hourBuckets)
                        } else {
                            Text("No comparable latency samples captured for this provider yet.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }

                        activityBucketsChart("Activity Per Day", buckets: dashboard.activityDailyBuckets)
                        activityBucketsChart("Activity by Weekday", buckets: dashboard.activityWeekdayBuckets)
                        activityBucketsChart("Activity by Period", buckets: dashboard.activityPeriodBuckets)
                        activityBucketsChart("Activity by Hour", buckets: dashboard.activityHourBuckets)
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
        bucketBarChart(
            title: title,
            buckets: buckets,
            barColor: .accentColor,
            barValue: chartValue(for:),
            topLabel: { latencyLabel(chartValue(for: $0)) },
            bottomLabel: \.label,
            helpText: { bucket in
                "\(bucket.aggregate.count) samples, avg \(latencyLabel(bucket.aggregate.averageLatencyMs)), p50 \(bucket.aggregate.p50LatencyMs.map { "\($0)ms" } ?? "n/a"), p95 \(bucket.aggregate.p95LatencyMs.map { "\($0)ms" } ?? "n/a")"
            }
        )
    }

    private func activityBucketsChart(_ title: String, buckets: [ProviderActivityBucketPoint]) -> some View {
        bucketBarChart(
            title: title,
            buckets: buckets,
            barColor: .green,
            barValue: { Double($0.count) },
            topLabel: { "\($0.count)" },
            bottomLabel: \.label,
            helpText: { "\($0.count) captured interaction(s)" }
        )
    }

    /// Shared chart shell for the two bucket variants in this view.
    /// Layout: title + empty-state-or-scrollable-bars + capsule background.
    /// Height of each bar is `barValue(bucket) / max(barValue)` of the chart
    /// area (28pt reserved for header, frame fixed at 120pt).
    private func bucketBarChart<Bucket: Identifiable>(
        title: String,
        buckets: [Bucket],
        barColor: Color,
        barValue: @escaping (Bucket) -> Double,
        topLabel: @escaping (Bucket) -> String,
        bottomLabel: @escaping (Bucket) -> String,
        helpText: @escaping (Bucket) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))

            if buckets.isEmpty {
                Text("No data")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                GeometryReader { geo in
                    let maxValue = max(buckets.map(barValue).max() ?? 1, 1)
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
                                    Text(topLabel(bucket))
                                        .font(.system(size: 8, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)

                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(barColor.opacity(0.65))
                                        .frame(
                                            width: barWidth,
                                            height: max(2, barArea * CGFloat(barValue(bucket)) / CGFloat(maxValue))
                                        )

                                    Text(bottomLabel(bucket))
                                        .font(.system(size: 8))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                                .frame(width: barWidth + 6)
                                .help(helpText(bucket))
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

    private func chartValue(for bucket: ProviderLatencyBucketPoint) -> Double {
        if let p50 = bucket.aggregate.p50LatencyMs {
            return Double(p50)
        }
        return bucket.aggregate.averageLatencyMs
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

    private func comparableLatencyExplanation(for metricKinds: [ProviderLatencyMetricKind]) -> String {
        let labels = metricKinds.map(\.displayName)
        if labels.isEmpty {
            return "Comparable latency is unavailable for the current provider."
        }
        if labels.count == 1 {
            return "Comparable latency currently comes from \(labels[0])."
        }
        return "Comparable latency combines \(labels.joined(separator: " + ")) into one provider-level view."
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
