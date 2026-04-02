import SwiftUI

// MARK: - About Settings

struct AboutSettingsView: View {
    var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // App Info
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Chau7", "Chau7"))
                        .font(.title)
                        .fontWeight(.bold)
                    Text(L("settings.about.tagline", "AI CLI Terminal Companion"))
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
            SettingsSectionHeader(L("settings.about.versionInformation", "Version Information"), icon: "info.circle")

            SettingsInfoRow(label: L("settings.about.application", "Application"), value: ProcessInfo.processInfo.processName, monospaced: true)
            SettingsInfoRow(label: L("settings.about.bundleId", "Bundle ID"), value: Bundle.main.bundleIdentifier ?? L("settings.about.notBundled", "Not bundled"), monospaced: true)
            SettingsInfoRow(label: L("settings.about.version", "Version"), value: bundleVersion, monospaced: true)
            SettingsInfoRow(label: L("settings.about.built", "Built"), value: buildDateString, monospaced: true)

            Divider()
                .padding(.vertical, 8)

            // System Info
            SettingsSectionHeader(L("settings.about.systemInformation", "System Information"), icon: "desktopcomputer")

            SettingsInfoRow(label: "macOS", value: ProcessInfo.processInfo.operatingSystemVersionString, monospaced: true)
            SettingsInfoRow(label: L("settings.about.architecture", "Architecture"), value: machineArchitecture, monospaced: true)
            SettingsInfoRow(label: L("settings.about.shell", "Shell"), value: ProcessInfo.processInfo.environment["SHELL"] ?? L("settings.about.unknown", "Unknown"), monospaced: true)

            Divider()
                .padding(.vertical, 8)

            // Links
            SettingsSectionHeader(L("settings.about.links", "Links"), icon: "link")

            HStack(spacing: 16) {
                Link(destination: URL(string: "https://github.com/anthropics/chau7")!) {
                    Label(L("GitHub", "GitHub"), systemImage: "chevron.left.forwardslash.chevron.right")
                }

                Link(destination: URL(string: "https://github.com/anthropics/chau7/issues")!) {
                    Label(L("settings.about.reportIssue", "Report Issue"), systemImage: "exclamationmark.bubble")
                }

                Link(destination: URL(string: "https://github.com/anthropics/chau7/blob/main/README.md")!) {
                    Label(L("settings.about.documentation", "Documentation"), systemImage: "book")
                }
            }
            .buttonStyle(.link)

            Divider()
                .padding(.vertical, 8)

            // Logs
            SettingsSectionHeader(L("settings.about.applicationLog", "Application Log"), icon: "doc.text")

            SettingsInfoRow(label: L("settings.about.logPath", "Log Path"), value: model.logFilePath, monospaced: true)

            SettingsButtonRow(buttons: [
                .init(title: L("settings.about.revealInFinder", "Reveal in Finder"), icon: "folder") {
                    model.revealLogFile()
                },
                .init(title: L("settings.about.debugConsole", "Debug Console"), icon: "terminal") {
                    DebugConsoleController.shared.show()
                }
            ])

            Divider()
                .padding(.vertical, 8)

            // Acknowledgments
            SettingsSectionHeader(L("settings.about.acknowledgments", "Acknowledgments"), icon: "heart")

            SettingsDescription(text: L("settings.about.stackSummary", "Chau7 combines Swift, Rust, and Go components across the app, terminal backend, and local proxy."))
            SettingsDescription(text: L("settings.about.licenseSummary", "Open-source acknowledgments and third-party notice files are listed in Help > Technology, Licenses & Acknowledgments."))

            SettingsButtonRow(buttons: [
                .init(title: L("settings.about.openAcknowledgments", "Open Acknowledgments"), icon: "doc.text.magnifyingglass") {
                    AppDelegate.shared?.showTechnologyLicenses()
                }
            ])

            SettingsDescription(text: L("settings.about.copyright", "Copyright © 2024-2025. All rights reserved."))
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

    private var buildDateString: String {
        guard let execURL = Bundle.main.executableURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: execURL.path),
              let date = attrs[.modificationDate] as? Date else {
            return "Unknown"
        }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: date)
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
