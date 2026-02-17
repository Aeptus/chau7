import SwiftUI

// MARK: - Token Optimization Settings

/// Settings view for configuring RTK (Reduced Token Kit) token optimization.
/// Allows users to choose between Off, All Commands, AI Only, and Manual modes.
struct TokenOptimizationSettingsView: View {
    @ObservedObject private var settings = FeatureSettings.shared
    @State private var wrapperStatus: WrapperStatus = .notInstalled

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Mode Selection
            SettingsSectionHeader(
                L("rtk.settings.mode", "Optimization Mode"),
                icon: "bolt.horizontal.circle"
            )

            SettingsPicker(
                label: L("rtk.settings.mode.label", "Mode"),
                help: L("rtk.settings.mode.help", "Controls when token-optimized command output is active"),
                selection: modeBinding,
                options: TokenOptimizationMode.allCases.map { mode in
                    (value: mode.rawValue, label: mode.displayName)
                }
            )

            // Mode description
            modeDescriptionView

            if settings.tokenOptimizationMode != .off {
                Divider()
                    .padding(.vertical, 8)

                // Status
                SettingsSectionHeader(
                    L("rtk.settings.status", "Status"),
                    icon: "circle.fill"
                )

                HStack(spacing: 8) {
                    statusIndicator
                    Text(statusText)
                        .font(.body)
                }
                .padding(.vertical, 4)

                Divider()
                    .padding(.vertical, 8)

                // Per-Tab Control Info
                SettingsSectionHeader(
                    L("rtk.settings.perTab", "Per-Tab Control"),
                    icon: "rectangle.stack"
                )

                perTabInfoView

                Divider()
                    .padding(.vertical, 8)

                // Supported Commands
                SettingsSectionHeader(
                    L("rtk.settings.commands", "Optimized Commands"),
                    icon: "terminal"
                )

                commandsList

                Divider()
                    .padding(.vertical, 8)

                // How It Works
                SettingsSectionHeader(
                    L("rtk.settings.howItWorks", "How It Works"),
                    icon: "questionmark.circle"
                )

                howItWorksView
            }
        }
        .onAppear {
            updateWrapperStatus()
        }
        .onChange(of: settings.tokenOptimizationMode) { newMode in
            handleModeChange(newMode)
        }
    }

    // MARK: - Mode Binding

    private var modeBinding: Binding<String> {
        Binding(
            get: { settings.tokenOptimizationMode.rawValue },
            set: { newValue in
                if let mode = TokenOptimizationMode(rawValue: newValue) {
                    settings.tokenOptimizationMode = mode
                }
            }
        )
    }

    // MARK: - Mode Description

    @ViewBuilder
    private var modeDescriptionView: some View {
        let mode = settings.tokenOptimizationMode
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: modeIcon(for: mode))
                .font(.system(size: 24))
                .foregroundStyle(modeColor(for: mode))
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(mode.displayName)
                    .font(.headline)
                Text(mode.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if mode != .off {
                    Text(modeDetail(for: mode))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }

    private func modeIcon(for mode: TokenOptimizationMode) -> String {
        switch mode {
        case .off: return "bolt.slash"
        case .allTabs: return "bolt.fill"
        case .aiOnly: return "sparkles"
        case .manual: return "hand.tap"
        }
    }

    private func modeColor(for mode: TokenOptimizationMode) -> Color {
        switch mode {
        case .off: return .secondary
        case .allTabs: return .yellow
        case .aiOnly: return .purple
        case .manual: return .blue
        }
    }

    private func modeDetail(for mode: TokenOptimizationMode) -> String {
        switch mode {
        case .off:
            return ""
        case .allTabs:
            return L("rtk.mode.allTabs.detail", "Every tab shows a bolt icon. Click it to opt out a specific tab.")
        case .aiOnly:
            return L("rtk.mode.aiOnly.detail", "The bolt icon appears when an AI CLI (Claude Code, Codex, etc.) is detected. Click to force on/off per tab.")
        case .manual:
            return L("rtk.mode.manual.detail", "No tabs are optimized by default. Click the bolt icon on any tab to opt in.")
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusIndicator: some View {
        Circle()
            .fill(wrapperStatus == .installed ? Color.green : Color.secondary)
            .frame(width: 8, height: 8)
    }

    private var statusText: String {
        switch wrapperStatus {
        case .notInstalled:
            return L("rtk.status.notInstalled", "Wrapper scripts not installed")
        case .installed:
            return String(
                format: L("rtk.status.installed", "%d wrapper scripts installed"),
                RTKManager.supportedCommands.count
            )
        }
    }

    // MARK: - Per-Tab Info

    @ViewBuilder
    private var perTabInfoView: some View {
        let mode = settings.tokenOptimizationMode
        VStack(alignment: .leading, spacing: 8) {
            switch mode {
            case .off:
                EmptyView()
            case .allTabs:
                infoRow(
                    icon: "bolt.fill",
                    iconColor: .yellow,
                    text: L("rtk.perTab.allTabs.default", "All tabs are optimized by default")
                )
                infoRow(
                    icon: "bolt.slash",
                    iconColor: .secondary,
                    text: L("rtk.perTab.allTabs.optOut", "Click the bolt to opt out a specific tab")
                )
            case .aiOnly:
                infoRow(
                    icon: "bolt.fill",
                    iconColor: .yellow,
                    text: L("rtk.perTab.aiOnly.detected", "Bolt appears when AI CLI is detected")
                )
                infoRow(
                    icon: "hand.tap",
                    iconColor: .blue,
                    text: L("rtk.perTab.aiOnly.cycle", "Click cycles: auto -> force off -> force on -> auto")
                )
            case .manual:
                infoRow(
                    icon: "bolt.slash",
                    iconColor: .secondary,
                    text: L("rtk.perTab.manual.default", "No tabs are optimized by default")
                )
                infoRow(
                    icon: "bolt.fill",
                    iconColor: .yellow,
                    text: L("rtk.perTab.manual.optIn", "Click the bolt to opt in a specific tab")
                )
            }
        }
    }

    @ViewBuilder
    private func infoRow(icon: String, iconColor: Color, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 20)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Commands List

    @ViewBuilder
    private var commandsList: some View {
        let commands = RTKManager.supportedCommands
        VStack(alignment: .leading, spacing: 4) {
            ForEach(commands, id: \.self) { command in
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                    Text(command)
                        .font(.system(.body, design: .monospaced))
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - How It Works

    @ViewBuilder
    private var howItWorksView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("rtk.howItWorks.desc", "When active, Chau7 prepends a directory of wrapper scripts to your PATH:"))
                .font(.caption)
                .foregroundStyle(.secondary)

            codeRow("~/.chau7/rtk_bin/")

            Text(L("rtk.howItWorks.mechanism", "Each wrapper checks a per-session flag file to decide whether to optimize output. When inactive, the real binary runs directly with zero overhead."))
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(L("rtk.howItWorks.flagDir", "Flag files location:"))
                .font(.caption)
                .foregroundStyle(.secondary)

            codeRow("~/.chau7/rtk_active/<SESSION_ID>")

            Text(L("rtk.howItWorks.cleanup", "All flag files and wrappers are cleaned up when the app quits or when the mode is set to Off."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func codeRow(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(4)
    }

    // MARK: - Actions

    private func handleModeChange(_ newMode: TokenOptimizationMode) {
        // RTKManager setup/teardown is handled centrally by OverlayTabsModel's
        // .tokenOptimizationModeChanged observer. We only update local UI state.
        updateWrapperStatus()
    }

    private func updateWrapperStatus() {
        let mode = settings.tokenOptimizationMode
        guard mode != .off else {
            wrapperStatus = .notInstalled
            return
        }

        let fm = FileManager.default
        let wrapperDir = RTKManager.shared.wrapperBinDir.path
        if fm.fileExists(atPath: wrapperDir) {
            wrapperStatus = .installed
        } else {
            wrapperStatus = .notInstalled
        }
    }
}

// MARK: - Wrapper Status

private enum WrapperStatus {
    case notInstalled
    case installed
}

// MARK: - Preview

#if DEBUG
struct TokenOptimizationSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        TokenOptimizationSettingsView()
            .frame(width: 500, height: 700)
    }
}
#endif
