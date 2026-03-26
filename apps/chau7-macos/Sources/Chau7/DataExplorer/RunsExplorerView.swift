import SwiftUI
import Chau7Core

struct RunsExplorerView: View {
    @State private var runs: [TelemetryRun] = []
    @State private var selectedRunID: String?
    @State private var toolSummary: [(tool: String, count: Int)] = []
    @State private var turns: [TelemetryTurn] = []

    var body: some View {
        HSplitView {
            // Runs list
            VStack(spacing: 0) {
                if runs.isEmpty {
                    VStack {
                        Spacer()
                        Text("No AI runs recorded yet")
                            .foregroundStyle(.secondary)
                        Text("AI session telemetry will appear here")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    List(runs, selection: $selectedRunID) { run in
                        RunRow(run: run)
                            .tag(run.id)
                    }
                    .listStyle(.plain)
                }
            }
            .frame(minWidth: 400)

            // Detail pane
            if let runID = selectedRunID {
                RunDetailView(runID: runID, toolSummary: toolSummary, turns: turns)
                    .frame(minWidth: 300)
            } else {
                VStack {
                    Spacer()
                    Text("Select a run to view details")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(minWidth: 300)
            }
        }
        .onAppear { reload() }
        .onChange(of: selectedRunID) { newID in
            guard let id = newID else {
                toolSummary = []
                turns = []
                return
            }
            toolSummary = TelemetryStore.shared.toolCallSummary(runID: id)
            turns = TelemetryStore.shared.getTurns(runID: id)
        }
    }

    private func reload() {
        let filter = TelemetryRunFilter(limit: 100)
        runs = TelemetryStore.shared.listRuns(filter: filter)
    }
}

private struct RunRow: View {
    let run: TelemetryRun

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                // Provider badge
                Text(run.provider.capitalized)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(providerColor.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(providerColor)

                if let model = run.model {
                    Text(model)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // Cost
                if let cost = run.costUSD, cost > 0 {
                    Text(String(format: "$%.2f", cost))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.orange)
                }
            }

            HStack {
                // Repo
                if let repo = run.repoPath {
                    Text(URL(fileURLWithPath: repo).lastPathComponent)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Tokens
                let inT = run.totalInputTokens ?? 0
                let outT = run.totalOutputTokens ?? 0
                if inT + outT > 0 {
                    Text(formatTokens(inT + outT))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                // Turns
                if run.turnCount > 0 {
                    Text("\(run.turnCount)t")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                // Time
                Text(formatDate(run.startedAt))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var providerColor: Color {
        switch run.provider.lowercased() {
        case "claude": return .purple
        case "codex": return .green
        case "cursor": return .blue
        default: return .secondary
        }
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.0fK", Double(count) / 1_000) }
        return "\(count)"
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}

private struct RunDetailView: View {
    let runID: String
    let toolSummary: [(tool: String, count: Int)]
    let turns: [TelemetryTurn]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Tool call breakdown
                if !toolSummary.isEmpty {
                    Text("Tool Calls")
                        .font(.system(size: 13, weight: .semibold))
                    ForEach(toolSummary, id: \.tool) { entry in
                        HStack {
                            Text(entry.tool)
                                .font(.system(size: 12, design: .monospaced))
                            Spacer()
                            Text("\(entry.count)")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Divider()

                // Turns
                Text("Turns (\(turns.count))")
                    .font(.system(size: 13, weight: .semibold))
                ForEach(turns) { turn in
                    TurnRow(turn: turn)
                }
            }
            .padding()
        }
    }
}

private struct TurnRow: View {
    let turn: TelemetryTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(turn.role.rawValue)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(roleColor.opacity(0.2))
                    .foregroundStyle(roleColor)
                    .clipShape(RoundedRectangle(cornerRadius: 3))

                if let tokens = turn.inputTokens, tokens > 0 {
                    Text("\(tokens) in")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if let tokens = turn.outputTokens, tokens > 0 {
                    Text("\(tokens) out")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let ts = turn.timestamp {
                    let f = DateFormatter()
                    Text({ f.dateFormat = "HH:mm:ss"; return f.string(from: ts) }())
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            if let content = turn.content, !content.isEmpty {
                Text(content)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(3)
                    .foregroundStyle(.primary.opacity(0.8))
            }
        }
        .padding(.vertical, 2)
    }

    private var roleColor: Color {
        switch turn.role {
        case .human: return .blue
        case .assistant: return .green
        case .system: return .orange
        case .toolResult: return .purple
        }
    }
}
