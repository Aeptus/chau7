import SwiftUI

/// A panel for assessing task completion (success/failure)
public struct TaskAssessmentView: View {
    let task: TrackedTask
    let onApprove: (String?) -> Void
    let onFail: (String?) -> Void
    let onCancel: () -> Void

    @State private var note: String = ""
    @State private var showNoteField = false

    public init(
        task: TrackedTask,
        onApprove: @escaping (String?) -> Void,
        onFail: @escaping (String?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.task = task
        self.onApprove = onApprove
        self.onFail = onFail
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("Task Complete?")
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Task summary
            VStack(alignment: .leading, spacing: 4) {
                Text(task.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)

                HStack(spacing: 12) {
                    Label("\(task.totalAPICalls) calls", systemImage: "arrow.up.arrow.down")
                    Label("\(task.totalTokens) tokens", systemImage: "text.word.spacing")
                    Label(task.formattedCost, systemImage: "dollarsign.circle")
                    Label(task.formattedDuration, systemImage: "clock")
                }
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(6)

            // Note field (optional)
            if showNoteField {
                TextField("Add a note (optional)", text: $note)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
            }

            // Action buttons
            HStack(spacing: 8) {
                Button(action: { showNoteField.toggle() }) {
                    Image(systemName: showNoteField ? "note.text.badge.plus" : "note.text")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Add a note")

                Spacer()

                Button(action: { onFail(note.isEmpty ? nil : note) }) {
                    Label("Failed", systemImage: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.small)

                Button(action: { onApprove(note.isEmpty ? nil : note) }) {
                    Label("Success", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.windowBackgroundColor))
                .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        )
        .frame(width: 320)
    }
}

/// A compact inline assessment bar for the terminal header
public struct TaskAssessmentBar: View {
    let task: TrackedTask
    let onApprove: () -> Void
    let onFail: () -> Void

    public var body: some View {
        HStack(spacing: 8) {
            // Task indicator
            Circle()
                .fill(Color.accentColor)
                .frame(width: 6, height: 6)

            Text(task.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)

            Spacer()

            // Stats
            HStack(spacing: 6) {
                Text("\(task.totalTokens)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(.secondary)

                Text(task.formattedCost)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(.secondary)
            }

            // Quick actions
            HStack(spacing: 4) {
                Button(action: onApprove) {
                    Image(systemName: "checkmark.circle")
                        .foregroundColor(.green)
                }
                .buttonStyle(.plain)
                .help("Mark as success")

                Button(action: onFail) {
                    Image(systemName: "xmark.circle")
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
                .help("Mark as failed")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.8))
        .cornerRadius(4)
    }
}

/// Task status indicator for the tab bar
public struct TaskStatusIndicator: View {
    let task: TrackedTask?
    let candidate: TaskCandidate?

    public var body: some View {
        Group {
            if let candidate = candidate {
                // Pending candidate
                Circle()
                    .fill(Color.orange)
                    .frame(width: 8, height: 8)
                    .overlay(
                        Circle()
                            .stroke(Color.orange.opacity(0.5), lineWidth: 2)
                            .scaleEffect(1.5)
                    )
                    .help("New task: \(candidate.suggestedName)")
            } else if let task = task, task.state == .active {
                // Active task
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
                    .help("Task: \(task.name)")
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
struct TaskAssessmentView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 30) {
            TaskAssessmentView(
                task: TrackedTask(
                    id: "task_preview",
                    candidateId: nil,
                    tabId: "tab_1",
                    sessionId: "sess_1",
                    projectPath: "/Users/dev/project",
                    name: "Fix login redirect bug",
                    state: .active,
                    startMethod: .autoConfirmed,
                    trigger: .idleGap,
                    startedAt: Date().addingTimeInterval(-1800),
                    completedAt: nil,
                    totalAPICalls: 12,
                    totalTokens: 45000,
                    totalCostUSD: 0.234
                ),
                onApprove: { _ in },
                onFail: { _ in },
                onCancel: {}
            )

            TaskAssessmentBar(
                task: TrackedTask(
                    id: "task_preview",
                    candidateId: nil,
                    tabId: "tab_1",
                    sessionId: "sess_1",
                    projectPath: "/Users/dev/project",
                    name: "Implement user auth",
                    state: .active,
                    startMethod: .manual,
                    trigger: .manual,
                    startedAt: Date().addingTimeInterval(-600),
                    completedAt: nil,
                    totalAPICalls: 5,
                    totalTokens: 12000,
                    totalCostUSD: 0.089
                ),
                onApprove: {},
                onFail: {}
            )
            .frame(width: 400)
        }
        .padding()
        .frame(width: 500, height: 400)
    }
}
#endif
