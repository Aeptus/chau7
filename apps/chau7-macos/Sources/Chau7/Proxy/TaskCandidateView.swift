import SwiftUI

/// A banner view displayed when a new task candidate is detected
/// Shows the suggested task name and allows the user to confirm or dismiss
public struct TaskCandidateView: View {
    let candidate: TaskCandidate
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    public init(
        candidate: TaskCandidate,
        onConfirm: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.candidate = candidate
        self.onConfirm = onConfirm
        self.onDismiss = onDismiss
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
            //
            // Driven by `TimelineView` rather than a `Timer` created in
            // `.onAppear`. The previous implementation scheduled a 10 Hz
            // repeating timer, never stored it, and only invalidated it when the
            // grace period expired — so confirming or dismissing the banner
            // (which removes the view) left a timer writing `@State` into a
            // detached view for the rest of the grace window, and that timer ran
            // in `.default` runloop mode so it also stalled during menu
            // tracking. It captured the `candidate` from appear-time, so a
            // replacement candidate froze the countdown at the old value.
            //
            // `TimelineView` is scoped to the view's lifetime, so there is
            // nothing to invalidate, and each tick re-reads
            // `candidate.graceRemainingMs` (computed from `gracePeriodEnd`), so
            // replacing the candidate is correct for free.
            TimelineView(.periodic(from: .now, by: TaskCandidateView.countdownTickInterval)) { _ in
                let graceRemaining = candidate.graceRemainingMs
                if graceRemaining > 0 {
                    Text(String(format: L("task.graceSeconds", "%ds"), graceRemaining / 1000))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(4)
                }
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
    }

    /// The label renders whole seconds, so a 5x refresh rate is more than
    /// enough and costs 5x less than the previous 10 Hz. Shared with
    /// `TaskCandidateToast` so both views tick together.
    fileprivate static let countdownTickInterval: Double = 0.2
}

/// A compact toast-style notification for task candidates
public struct TaskCandidateToast: View {
    let candidate: TaskCandidate
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    @State private var isHovered = false

    /// Fraction of the grace window still to run, clamped to `0...1`. Derived
    /// from `createdAt`/`gracePeriodEnd` so it is a pure function of the
    /// candidate plus "now", and therefore testable.
    private var graceProgress: CGFloat {
        let total = candidate.gracePeriodEnd.timeIntervalSince(candidate.createdAt)
        guard total > 0 else { return 0 }
        let remainingSeconds = Double(candidate.graceRemainingMs) / 1000
        return CGFloat(min(max(remainingSeconds / total, 0), 1))
    }

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
                // Progress ring. Driven from `gracePeriodEnd` over the actual
                // grace window rather than dividing a live remaining-time value
                // by a hard-coded 5000 ms, so the ring drains to empty at the
                // real deadline instead of being wrong whenever the grace
                // period is not exactly five seconds.
                TimelineView(.periodic(from: .now, by: TaskCandidateView.countdownTickInterval)) { _ in
                    Circle()
                        .trim(from: 0, to: graceProgress)
                        .stroke(Color.accentColor, lineWidth: 2)
                        .frame(width: 16, height: 16)
                        .rotationEffect(.degrees(-90))
                }
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
