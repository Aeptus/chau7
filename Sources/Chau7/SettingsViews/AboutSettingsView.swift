import SwiftUI

// MARK: - About Settings

struct AboutSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // App Info
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Chau7")
                        .font(.title)
                        .fontWeight(.bold)
                    Text("AI CLI Terminal Companion")
                        .foregroundStyle(.secondary)
                    Text(bundleVersion)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 8)

            Divider()
                .padding(.vertical, 8)

            // Version Details
            SettingsSectionHeader("Version Information", icon: "info.circle")

            VStack(alignment: .leading, spacing: 4) {
                SettingsInfoRow(label: "Application", value: ProcessInfo.processInfo.processName, monospaced: true)
                SettingsInfoRow(label: "Bundle ID", value: Bundle.main.bundleIdentifier ?? "Not bundled", monospaced: true)
                SettingsInfoRow(label: "Version", value: bundleVersion, monospaced: true)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(8)

            Divider()
                .padding(.vertical, 8)

            // System Info
            SettingsSectionHeader("System Information", icon: "desktopcomputer")

            VStack(alignment: .leading, spacing: 4) {
                SettingsInfoRow(label: "macOS", value: ProcessInfo.processInfo.operatingSystemVersionString, monospaced: true)
                SettingsInfoRow(label: "Architecture", value: machineArchitecture, monospaced: true)
                SettingsInfoRow(label: "Shell", value: ProcessInfo.processInfo.environment["SHELL"] ?? "Unknown", monospaced: true)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(8)

            Divider()
                .padding(.vertical, 8)

            // Links
            SettingsSectionHeader("Links", icon: "link")

            HStack(spacing: 16) {
                Link(destination: URL(string: "https://github.com/anthropics/chau7")!) {
                    Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }

                Link(destination: URL(string: "https://github.com/anthropics/chau7/issues")!) {
                    Label("Report Issue", systemImage: "exclamationmark.bubble")
                }

                Link(destination: URL(string: "https://github.com/anthropics/chau7/blob/main/README.md")!) {
                    Label("Documentation", systemImage: "book")
                }
            }
            .buttonStyle(.link)

            Divider()
                .padding(.vertical, 8)

            // Logs
            SettingsSectionHeader("Application Log", icon: "doc.text")

            SettingsInfoRow(label: "Log Path", value: model.logFilePath, monospaced: true)

            SettingsButtonRow(buttons: [
                .init(title: "Reveal in Finder", icon: "folder") {
                    model.revealLogFile()
                },
                .init(title: "Debug Console", icon: "terminal") {
                    DebugConsoleController.shared.show()
                }
            ])

            Divider()
                .padding(.vertical, 8)

            // Acknowledgments
            SettingsSectionHeader("Acknowledgments", icon: "heart")

            SettingsDescription(text: "Chau7 is built with SwiftTerm for terminal emulation.")
            SettingsDescription(text: "Copyright © 2024-2025. All rights reserved.")
        }
    }

    private var bundleVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case let (short?, build?):
            return "\(short) (\(build))"
        case let (short?, nil):
            return short
        case let (nil, build?):
            return build
        default:
            return "Development Build"
        }
    }

    private var machineArchitecture: String {
        #if arch(arm64)
        return "Apple Silicon (arm64)"
        #elseif arch(x86_64)
        return "Intel (x86_64)"
        #else
        return "Unknown"
        #endif
    }
}
