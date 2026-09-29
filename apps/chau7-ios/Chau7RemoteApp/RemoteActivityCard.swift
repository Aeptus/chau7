import Chau7Core
import SwiftUI

/// Native surface for the agent's *current* activity.
///
/// The Mac already publishes a structured `RemoteActivityState` for every tab,
/// and the phone already decodes it — it was only ever used to drive the
/// lock-screen Live Activity. That data is exactly what a person wants when they
/// pick up the phone: which tool is running, what it is doing, and whether it is
/// blocked waiting on them. Showing it as a card means the common case ("what is
/// it doing, and do I need to approve something?") does not require reading a
/// re-wrapped terminal at all.
///
/// Deliberately a *current state* view, not a timeline. The Mac publishes one
/// snapshot per tab, not a history, so anything claiming to be a log of past
/// tool calls would have to be invented here rather than read from the wire.
struct RemoteActivityCard: View {
    let activity: RemoteActivityState
    let onApprove: () -> Void
    let onDeny: () -> Void

    private var isBlocked: Bool {
        activity.status == .approvalRequired
    }

    private var tint: Color {
        switch activity.status {
        case .approvalRequired: .orange
        case .waitingInput: .yellow
        case .failed: .red
        case .completed: .green
        case .running: .accentColor
        case .idle: .secondary
        }
    }

    private var statusText: String {
        switch activity.status {
        case .idle: "Idle"
        case .running: "Running"
        case .approvalRequired: "Needs approval"
        case .waitingInput: "Waiting for input"
        case .completed: "Done"
        case .failed: "Failed"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
                Text(activity.toolName)
                    .font(.subheadline.weight(.semibold))
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(tint)
                Spacer(minLength: 0)
            }
            Text(activity.headline)
                .font(.footnote)
                .foregroundStyle(.primary)
                .lineLimit(2)
            if let detail = activity.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            if let approval = activity.approval {
                VStack(alignment: .leading, spacing: 6) {
                    Text(approval.flaggedCommand.isEmpty ? approval.command : approval.flaggedCommand)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                    HStack(spacing: 10) {
                        Button(role: .destructive, action: onDeny) {
                            Text("Deny").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        Button(action: onApprove) {
                            Text("Approve").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(tint.opacity(isBlocked ? 0.6 : 0.15))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(activity.toolName), \(statusText). \(activity.headline)")
    }
}
