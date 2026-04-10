import SwiftUI
import Chau7Core

// MARK: - Daily Trend Chart

struct DailyTrendChart: View {
    let data: [ProxyDailyAnalyticsPoint]
    @State private var metric: Metric = .cost

    enum Metric: String, CaseIterable {
        case cost = "Cost"
        case tokens = "Tokens"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Daily Trends")
                    .font(.headline)
                Spacer()
                Picker("", selection: $metric) {
                    ForEach(Metric.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
            }

            if data.isEmpty {
                Text("No data for this period")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 140, alignment: .center)
            } else {
                GeometryReader { geo in
                    let maxVal = data.map { metricValue($0) }.max() ?? 1
                    let barArea = geo.size.height - 28

                    HStack(alignment: .bottom, spacing: max(1, (geo.size.width - CGFloat(data.count) * 20) / CGFloat(max(data.count - 1, 1)))) {
                        ForEach(data) { point in
                            VStack(spacing: 2) {
                                Text(formatValue(metricValue(point)))
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)

                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.accentColor.opacity(0.65))
                                    .frame(
                                        width: 20,
                                        height: max(2, barArea * CGFloat(metricValue(point)) / CGFloat(max(maxVal, 0.001)))
                                    )

                                Text(dayLabel(point.date))
                                    .font(.system(size: 8))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                .frame(height: 140)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    private func metricValue(_ point: ProxyDailyAnalyticsPoint) -> Double {
        switch metric {
        case .cost: return point.totalCostUSD
        case .tokens: return Double(point.totalTokens)
        }
    }

    private func formatValue(_ value: Double) -> String {
        switch metric {
        case .cost:
            if value >= 1 { return String(format: "$%.0f", value) }
            return String(format: "$%.2f", value)
        case .tokens:
            let count = Int(value)
            if count >= 1_000_000 { return String(format: "%.0fM", value / 1_000_000) }
            if count >= 1000 { return String(format: "%.0fK", value / 1000) }
            return "\(count)"
        }
    }

    private func dayLabel(_ dateString: String) -> String {
        let parts = dateString.split(separator: "-")
        guard parts.count == 3 else { return dateString }
        return "\(parts[1])/\(parts[2])"
    }
}

// MARK: - Provider Breakdown

struct ProviderBreakdownView: View {
    let providers: [ProxyProviderAnalytics]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Provider Breakdown")
                .font(.headline)

            if providers.isEmpty {
                Text("No data")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    providerBars
                        .frame(maxWidth: .infinity)
                    ProviderPieChart(providers: providers)
                        .frame(width: 120, height: 120)
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    private var providerBars: some View {
        let maxCost = providers.map(\.totalCostUSD).max() ?? 1
        return VStack(spacing: 6) {
            ForEach(providers) { p in
                HStack(spacing: 8) {
                    Image(systemName: providerIcon(p.provider))
                        .font(.system(size: 11))
                        .foregroundColor(providerColor(p.provider))
                        .frame(width: 16)
                    Text(p.provider.capitalized)
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 70, alignment: .leading)

                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(providerColor(p.provider).opacity(0.6))
                            .frame(width: max(4, geo.size.width * CGFloat(p.totalCostUSD / max(maxCost, 0.001))))
                    }
                    .frame(height: 14)

                    Text(LocalizedFormatters.formatCostPrecise(p.totalCostUSD))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }
            }
        }
    }
}

// MARK: - Pie Chart

struct ProviderPieChart: View {
    let providers: [ProxyProviderAnalytics]

    var body: some View {
        let total = providers.reduce(0.0) { $0 + $1.totalCostUSD }
        let slices = providers.map { (provider: $0.provider, value: $0.totalCostUSD) }

        ZStack {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) / 2 - 4
                let inner = radius * 0.55
                var start = Angle.degrees(-90)

                for slice in slices {
                    let sweep = Angle.degrees(360 * slice.value / max(total, 0.001))
                    var path = Path()
                    path.addArc(center: center, radius: radius, startAngle: start, endAngle: start + sweep, clockwise: false)
                    path.addArc(center: center, radius: inner, startAngle: start + sweep, endAngle: start, clockwise: true)
                    path.closeSubpath()
                    context.fill(path, with: .color(providerColor(slice.provider)))
                    start += sweep
                }
            }

            VStack(spacing: 0) {
                Text(LocalizedFormatters.formatCostPrecise(total))
                    .font(.system(size: 10, design: .monospaced).bold())
                Text("total")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Model Breakdown Table

struct ModelBreakdownTable: View {
    let models: [ProxyModelAnalytics]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Model Breakdown")
                .font(.headline)

            if models.isEmpty {
                Text("No data")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .center)
            } else {
                let maxCost = models.first?.totalCostUSD ?? 1

                // Column headers
                HStack(spacing: 0) {
                    Text("Model")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Calls")
                        .frame(width: 55, alignment: .trailing)
                    Text("Tokens")
                        .frame(width: 70, alignment: .trailing)
                    Text("Cost")
                        .frame(width: 70, alignment: .trailing)
                    Spacer().frame(width: 60)
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

                Divider()

                ForEach(models) { m in
                    HStack(spacing: 0) {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(providerColor(m.provider))
                                .frame(width: 6, height: 6)
                            Text(m.model.isEmpty ? "(unknown)" : m.model)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Text(m.callCount.formatted())
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 55, alignment: .trailing)

                        Text(formatTokens(m.totalTokens))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .trailing)

                        Text(LocalizedFormatters.formatCostPrecise(m.totalCostUSD))
                            .font(.system(size: 10, design: .monospaced).bold())
                            .frame(width: 70, alignment: .trailing)

                        RoundedRectangle(cornerRadius: 3)
                            .fill(providerColor(m.provider).opacity(0.4))
                            .frame(width: 50 * CGFloat(m.totalCostUSD / max(maxCost, 0.001)), height: 8)
                            .frame(width: 60, alignment: .leading)
                    }
                    .padding(.vertical, 2)
                    .padding(.horizontal, 4)
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1000 { return String(format: "%.1fK", Double(count) / 1000) }
        return "\(count)"
    }
}

// MARK: - Recent Calls Table

struct RecentCallsTable: View {
    let calls: [APICallEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent API Calls")
                .font(.headline)

            if calls.isEmpty {
                Text("No calls recorded")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .center)
            } else {
                VStack(spacing: 0) {
                    ForEach(calls) { call in
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(call.isSuccess ? Color.green : Color.red)
                                    .frame(width: 6, height: 6)

                                Text(call.provider.rawValue)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(providerColor(call.provider.rawValue))

                                Text(call.model)
                                    .font(.system(size: 10, design: .monospaced))
                                    .lineLimit(1)

                                Spacer()

                                if call.totalTokens > 0 {
                                    Text(call.formattedTokens + " tok")
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }

                                if call.costUSD > 0 {
                                    Text(call.formattedCost)
                                        .font(.system(size: 9, design: .monospaced))
                                }

                                Text(call.formattedLatency)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)

                                Text(relativeTime(call.timestamp))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 50, alignment: .trailing)
                            }

                            if call.hasError {
                                Text(call.errorMessage ?? "")
                                    .font(.system(size: 9))
                                    .foregroundColor(.red)
                                    .lineLimit(1)
                                    .padding(.leading, 12)
                            }
                        }
                        .padding(.vertical, 3)

                        if call.id != calls.last?.id {
                            Divider().opacity(0.3)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }
}

// MARK: - Provider Helpers

func providerColor(_ name: String) -> Color {
    switch name.lowercased() {
    case "anthropic": return .purple
    case "openai": return .green
    case "gemini": return .blue
    default: return .gray
    }
}

func providerIcon(_ name: String) -> String {
    switch name.lowercased() {
    case "anthropic": return "brain.head.profile"
    case "openai": return "sparkles"
    case "gemini": return "diamond"
    default: return "questionmark.circle"
    }
}
