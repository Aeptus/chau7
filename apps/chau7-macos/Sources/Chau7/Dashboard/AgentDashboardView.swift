import Chau7Core
import SwiftUI

/// Multi-agent dashboard view — shows all AI agents working in a repo.
///
/// Displays agent cards with status, files, tokens, and conflicts.
/// Polls every 2 seconds via the model. Lives inside a non-terminal tab.
struct AgentDashboardView: View {
    @ObservedObject var model: AgentDashboardModel

    var body: some View {
        VStack(spacing: 0) {
            dashboardHeader
            Divider()

            if model.agentCards.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        agentCardsSection
                        if !model.conflicts.isEmpty {
                            conflictSection
                        }
                        timelineSection
                    }
                    .padding(16)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear { model.startPolling() }
        .onDisappear { model.stopPolling() }
    }

    // MARK: - Header

    private var dashboardHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 12))
                .foregroundStyle(.cyan)

            Text(model.repoName)
                .font(.system(size: 13, weight: .semibold))

            Spacer()

            // Stats pills
            if model.agentCount > 0 {
                statPill(
                    "\(model.agentCount) agent\(model.agentCount == 1 ? "" : "s")",
                    color: .secondary
                )
            }

            if model.totalTokens > 0 {
                statPill(formatTokens(model.totalTokens), color: .secondary)
            }

            // Status indicator
            Circle()
                .fill(statusColor(model.overallStatus))
                .frame(width: 8, height: 8)
                .help(statusLabel(model.overallStatus))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "person.3")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No agents running in this repo")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("Start an AI agent in a tab with this repository to see it here.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    // MARK: - Agent Cards

    private var agentCardsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.agentCards) { card in
                agentCard(card)
            }
        }
    }

    private func agentCard(_ card: AgentCardData) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Top row: identity + status + stats
            HStack {
                Circle()
                    .fill(stateColor(card.state))
                    .frame(width: 8, height: 8)

                Text(card.backendName.capitalized)
                    .font(.system(size: 12, weight: .semibold))

                Text("(\(card.state.rawValue))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Spacer()

                Text("Turns: \(card.turnCount)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)

                Text(card.formattedTokens + " tok")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            // Files touched
            if !card.touchedFiles.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text(card.touchedFiles.sorted().joined(separator: ", "))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }

            // Last tool + approval status
            HStack {
                if let tool = card.lastToolUsed {
                    Text("Last: \(tool)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                if card.pendingApproval != nil {
                    Label("Awaiting approval", systemImage: "clock.badge.questionmark")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }

                Spacer()

                // Actions
                Button {
                    model.stopAgent(sessionID: card.sessionID)
                } label: {
                    Text("Stop")
                        .font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)

                Button {
                    model.switchToTab(tabID: card.tabID)
                } label: {
                    Label("Tab", systemImage: "arrow.right.square")
                        .font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(card.pendingApproval != nil ? Color.orange.opacity(0.4) : Color.clear, lineWidth: 1)
        )
    }

    // MARK: - Conflicts

    private var conflictSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Conflicts", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)

            ForEach(model.conflicts) { conflict in
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)

                    Text(conflict.filePath)
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Text(conflict.agents.map(\.backendName.capitalized).joined(separator: " + "))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .padding(6)
                .background(Color.orange.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    // MARK: - Timeline

    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Timeline")
                .font(.system(size: 12, weight: .semibold))
                .padding(.bottom, 4)

            if model.timeline.isEmpty {
                Text("No events yet")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .italic()
            } else {
                ForEach(model.timeline.prefix(50)) { entry in
                    HStack(spacing: 6) {
                        Text(timeFormatter.string(from: entry.timestamp))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: 55, alignment: .leading)

                        Text(entry.backendName.capitalized)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(backendColor(entry.backendName))
                            .frame(width: 45, alignment: .leading)

                        Image(systemName: eventIcon(entry.type))
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                            .frame(width: 12)

                        Text(entry.message)
                            .font(.system(size: 10))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func statPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.08))
            .clipShape(Capsule())
    }

    private func stateColor(_ state: RuntimeSessionStateMachine.State) -> Color {
        switch state {
        case .ready: return .green
        case .busy: return .orange
        case .awaitingApproval, .waitingInput: return .yellow
        case .interrupted: return .orange
        case .failed: return .red
        case .stopped: return .gray
        case .starting: return .blue
        }
    }

    private func statusColor(_ status: OverallStatus) -> Color {
        switch status {
        case .idle: return .gray
        case .active: return .green
        case .hasConflicts: return .red
        case .hasApprovals: return .orange
        }
    }

    private func statusLabel(_ status: OverallStatus) -> String {
        switch status {
        case .idle: return "No agents active"
        case .active: return "Agents working"
        case .hasConflicts: return "File conflicts detected"
        case .hasApprovals: return "Approvals pending"
        }
    }

    private func backendColor(_ name: String) -> Color {
        switch name.lowercased() {
        case "claude": return .orange
        case "codex": return .green
        default: return .secondary
        }
    }

    private func eventIcon(_ type: String) -> String {
        switch type {
        case "tool_use": return "wrench"
        case "tool_result": return "checkmark"
        case "turn_started": return "play"
        case "turn_completed": return "stop"
        case "approval_needed": return "lock"
        case "approval_resolved": return "lock.open"
        case "state_changed": return "arrow.triangle.2.circlepath"
        default: return "circle.fill"
        }
    }

    private func formatTokens(_ count: Int) -> String {
        if count > 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count > 1000 { return String(format: "%.1fk", Double(count) / 1000) }
        return "\(count)"
    }

    private var timeFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }
}
