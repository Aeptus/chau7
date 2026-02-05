import SwiftUI
import AppKit

/// A SwiftUI confirmation sheet displayed when a dangerous command is detected.
///
/// Shows:
/// - A warning icon and title
/// - The dangerous command highlighted in red
/// - The matched pattern that triggered the warning
/// - Three action buttons: Execute, Cancel, Always Allow
/// - Optional checkbox: Do not show for this command again
///
/// Animates in/out smoothly via the standard sheet presentation.
/// All interactive elements carry accessibility labels.
struct DangerousCommandConfirmationView: View {
    /// The dangerous command that was intercepted.
    let command: String

    /// The pattern that the command matched against.
    let matchedPattern: String

    /// Callback invoked with the user decision.
    let onDecision: (Decision) -> Void

    /// Possible user decisions.
    enum Decision {
        case execute
        case cancel
        case alwaysAllow
    }

    @State private var dontShowAgain = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header
                .padding(.bottom, 16)

            Divider()

            // Command display
            commandSection
                .padding(.vertical, 16)

            Divider()

            // Pattern info
            patternSection
                .padding(.vertical, 12)

            Divider()

            // Actions
            actionButtons
                .padding(.top, 16)
        }
        .padding(24)
        .frame(width: 440)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Dangerous command confirmation dialog", "Dangerous command confirmation dialog"))
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(L("dangerousGuard.confirm.title", "Dangerous Command Detected"))
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)

                Text(L("dangerousGuard.confirm.subtitle", "This command matches a risky pattern and may cause irreversible changes."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var commandSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("dangerousGuard.confirm.commandLabel", "Command"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Text(command)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.red)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.red.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.red.opacity(0.2), lineWidth: 1)
                )
                .accessibilityLabel(L("dangerousGuard.confirm.accessibility.command", "Dangerous command: %@", command))
        }
    }

    private var patternSection: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(L("dangerousGuard.confirm.matchedLabel", "Matched pattern:"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(matchedPattern)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.orange)
                .accessibilityLabel(L("dangerousGuard.confirm.accessibility.pattern", "Matched pattern: %@", matchedPattern))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
            // Do not show again checkbox
            Toggle(isOn: $dontShowAgain) {
                Text(L("dangerousGuard.confirm.dontShowAgain", "Do not warn for this command again"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(L("dangerousGuard.confirm.accessibility.dontShowAgain", "Do not warn for this command again"))

            HStack(spacing: 12) {
                // Cancel (default safe action)
                Button {
                    onDecision(.cancel)
                } label: {
                    Text(L("dangerousGuard.confirm.cancel", "Cancel"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(L("dangerousGuard.confirm.accessibility.cancel", "Cancel command execution"))

                // Always Allow
                Button {
                    onDecision(.alwaysAllow)
                } label: {
                    Text(L("dangerousGuard.confirm.alwaysAllow", "Always Allow"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityLabel(L("Always allow this command without confirmation", "Always allow this command without confirmation"))

                // Execute (destructive action)
                Button {
                    if dontShowAgain {
                        onDecision(.alwaysAllow)
                    } else {
                        onDecision(.execute)
                    }
                } label: {
                    Text(L("dangerousGuard.confirm.execute", "Execute"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel(L("Execute the dangerous command", "Execute the dangerous command"))
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
struct DangerousCommandConfirmationView_Previews: PreviewProvider {
    static var previews: some View {
        DangerousCommandConfirmationView(
            command: "sudo rm -rf /",
            matchedPattern: "rm -rf",
            onDecision: { _ in }
        )
        .padding()
    }
}
#endif
