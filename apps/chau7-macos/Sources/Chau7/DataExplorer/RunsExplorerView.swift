import SwiftUI
import Chau7Core

struct RunsExplorerView: View {
    @State private var runs: [TelemetryRun] = []
    @State private var selectedRunID: String?
    @State private var toolSummary: [(tool: String, count: Int)] = []

    var body: some View {
        HSplitView {
            // Runs list
            VStack(spacing: 0) {
                if runs.isEmpty {
                    VStack {
                        Spacer()
                        Text(L("explorer.runs.noRuns", "No AI runs recorded yet"))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    // Summary bar
                    HStack {
                        Text(String(format: L("explorer.runs.count", "%d runs"), runs.count))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        let withTokens = runs.filter { $0.tokenUsage.hasAnyTokens }.count
                        if withTokens > 0 {
                            Text(String(format: L("explorer.runs.withTokens", "%d with token data"), withTokens))
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    Divider()

                    List(runs, selection: $selectedRunID) { run in
                        RunRow(run: run)
                            .tag(run.id)
                    }
                    .listStyle(.plain)
                }
            }
            .frame(minWidth: 420)

            // Detail pane
            if let runID = selectedRunID {
                RunDetailView(runID: runID, toolSummary: toolSummary)
                    .frame(minWidth: 300)
            } else {
                VStack {
                    Spacer()
                    Text(L("explorer.runs.selectRun", "Select a run to view details"))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(minWidth: 300)
            }
        }
        .onAppear { reload() }
        .onChange(of: selectedRunID) {
            guard let id = selectedRunID else { toolSummary = []
                return
            }
            toolSummary = TelemetryStore.shared.toolCallSummary(runID: id)
        }
    }

    private func reload() {
        let filter = TelemetryRunFilter(limit: 200)
        runs = TelemetryStore.shared.listRuns(filter: filter)
    }
}

// MARK: - Run Row

private struct RunRow: View {
    let run: TelemetryRun

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                // Provider badge
                Text(run.provider.capitalized)
                    .font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(providerColor.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(providerColor)

                // Repo name (not full path)
                Text(repoName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                // Relative time
                Text(relativeTime)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 8) {
                // Session ID (short, human-readable)
                Text(shortSessionID)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)

                if run.turnCount > 0 {
                    Label("\(run.turnCount)", systemImage: "bubble.left.and.bubble.right")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                // Tokens (only if non-zero)
                let totalTokens = run.tokenUsage.totalBillableTokens
                if totalTokens > 0 {
                    Text(formatTokens(totalTokens))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.blue)
                }

                if let model = run.model, !model.isEmpty {
                    Text(model)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer()
            }
        }
        .padding(.vertical, 3)
    }

    private var repoName: String {
        guard let path = run.repoPath, !path.isEmpty else {
            let cwd = run.cwd
            return URL(fileURLWithPath: cwd).lastPathComponent
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private var shortSessionID: String {
        let id = run.sessionID ?? run.id
        if id.count > 12 { return String(id.prefix(8)) }
        return id
    }

    private var relativeTime: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: run.startedAt, relativeTo: Date())
    }

    private var providerColor: Color {
        switch run.provider.lowercased() {
        case "claude": return .purple
        case "codex": return .green
        case "cline": return .orange
        case "chatgpt": return .teal
        default: return .secondary
        }
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1000 { return String(format: "%.0fK", Double(count) / 1000) }
        return "\(count)"
    }
}

// MARK: - Run Detail

private struct RunDetailView: View {
    let runID: String
    let toolSummary: [(tool: String, count: Int)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Tool call breakdown
                if !toolSummary.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("explorer.runs.toolCalls", "Tool Calls"))
                            .font(.system(size: 13, weight: .semibold))

                        let maxCount = toolSummary.first?.count ?? 1
                        ForEach(toolSummary, id: \.tool) { entry in
                            HStack(spacing: 8) {
                                Text(entry.tool)
                                    .font(.system(size: 12, design: .monospaced))
                                    .frame(width: 100, alignment: .trailing)

                                // Bar
                                GeometryReader { geo in
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.blue.opacity(0.6))
                                        .frame(width: geo.size.width * CGFloat(entry.count) / CGFloat(maxCount))
                                }
                                .frame(height: 14)

                                Text("\(entry.count)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 40, alignment: .trailing)
                            }
                        }
                    }
                } else {
                    VStack {
                        Spacer()
                        Text(L("explorer.runs.noToolCalls", "No tool calls recorded for this run"))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding()
        }
    }
}
