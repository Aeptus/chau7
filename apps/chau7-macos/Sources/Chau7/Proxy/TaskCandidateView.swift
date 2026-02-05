import SwiftUI

/// A banner view displayed when a new task candidate is detected
/// Shows the suggested task name and allows the user to confirm or dismiss
public struct TaskCandidateView: View {
    let candidate: TaskCandidate
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    @State private var graceRemaining: Int64

    public init(
        candidate: TaskCandidate,
        onConfirm: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.candidate = candidate
        self.onConfirm = onConfirm
        self.onDismiss = onDismiss
        self._graceRemaining = State(initialValue: candidate.graceRemainingMs)
    }

    public var body: some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: "list.bullet.clipboard")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.accentColor)

            // Task info
            VStack(alignment: .leading, spacing: 2) {
                Text(L("New task detected", "New task detected"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)

                Text(candidate.suggestedName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }

            Spacer()

            // Grace period countdown
            if graceRemaining > 0 {
                Text(String(format: L("task.graceSeconds", "%ds"), graceRemaining / 1000))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(4)
            }

            // Action buttons
            HStack(spacing: 8) {
                Button(action: onConfirm) {
                    Label(L("Confirm", "Confirm"), systemImage: "checkmark")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button(action: onDismiss) {
                    Label(L("Dismiss", "Dismiss"), systemImage: "xmark")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        )
        .onAppear {
            startCountdown()
        }
    }

    private func startCountdown() {
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            graceRemaining = candidate.graceRemainingMs
            if graceRemaining <= 0 {
                timer.invalidate()
            }
        }
    }
}

/// A compact toast-style notification for task candidates
public struct TaskCandidateToast: View {
    let candidate: TaskCandidate
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    @State private var isHovered = false

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet.clipboard.fill")
                .foregroundColor(.accentColor)

            Text(candidate.suggestedName)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)

            Spacer()

            if isHovered {
                HStack(spacing: 4) {
                    Button(action: onConfirm) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                    .buttonStyle(.plain)

                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                // Progress ring
                Circle()
                    .trim(from: 0, to: CGFloat(candidate.graceRemainingMs) / 5000.0)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .frame(width: 16, height: 16)
                    .rotationEffect(.degrees(-90))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.95))
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
struct TaskCandidateView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            TaskCandidateView(
                candidate: TaskCandidate(
                    id: "cand_preview",
                    tabId: "tab_1",
                    sessionId: "sess_1",
                    projectPath: "~/dev/project",
                    suggestedName: "Fix login redirect bug",
                    trigger: .idleGap,
                    confidence: 0.85,
                    gracePeriodEnd: Date().addingTimeInterval(5),
                    createdAt: Date()
                ),
                onConfirm: {},
                onDismiss: {}
            )
            .padding()

            TaskCandidateToast(
                candidate: TaskCandidate(
                    id: "cand_preview",
                    tabId: "tab_1",
                    sessionId: "sess_1",
                    projectPath: "~/dev/project",
                    suggestedName: "Implement user authentication",
                    trigger: .newSession,
                    confidence: 0.9,
                    gracePeriodEnd: Date().addingTimeInterval(3),
                    createdAt: Date()
                ),
                onConfirm: {},
                onDismiss: {}
            )
            .frame(width: 300)
            .padding()
        }
        .frame(width: 500, height: 200)
    }
}
#endif
