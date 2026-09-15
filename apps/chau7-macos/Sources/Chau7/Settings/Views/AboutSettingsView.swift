import SwiftUI
import AppKit

// MARK: - About Settings

struct AboutSettingsView: View {
    var model: AppModel
    @State private var supportInfoMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Chau7Style.Settings.pageSectionSpacing) {
            // App Info
            HStack(alignment: .top, spacing: Chau7Style.Settings.looseControlSpacing) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 54)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Chau7Style.Spacing.xxxSmall) {
                    Text(L("Chau7", "Chau7"))
                        .font(.title)
                        .fontWeight(.bold)
                    Text(L("settings.about.tagline", "AI CLI Terminal Companion"))
                        .foregroundStyle(.secondary)
                    Text(String(format: L("settings.about.versionLine", "Version %@"), bundleVersion))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(.bottom, Chau7Style.Settings.separatorVerticalPadding)
            .settingsSearchAnchor("about")

            SettingsDivider()

            // Support
            SettingsSectionHeader(L("settings.about.support", "Support"), icon: "questionmark.circle", anchorID: "aboutSupport")

            ViewThatFits(in: .horizontal) {
                HStack(spacing: Chau7Style.Settings.looseControlSpacing) {
                    aboutLink(
                        title: L("GitHub", "GitHub"),
                        systemImage: "chevron.left.forwardslash.chevron.right",
                        destination: "https://github.com/aeptus/chau7"
                    )
                    aboutLink(
                        title: L("settings.about.reportIssue", "Report Issue"),
                        systemImage: "exclamationmark.bubble",
                        destination: "https://github.com/aeptus/chau7/issues"
                    )
                    aboutLink(
                        title: L("settings.about.documentation", "Documentation"),
                        systemImage: "book",
                        destination: "https://github.com/aeptus/chau7/blob/main/README.md"
                    )
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: Chau7Style.Settings.inlineControlSpacing) {
                    aboutLink(
                        title: L("GitHub", "GitHub"),
                        systemImage: "chevron.left.forwardslash.chevron.right",
                        destination: "https://github.com/aeptus/chau7"
                    )
                    aboutLink(
                        title: L("settings.about.reportIssue", "Report Issue"),
                        systemImage: "exclamationmark.bubble",
                        destination: "https://github.com/aeptus/chau7/issues"
                    )
                    aboutLink(
                        title: L("settings.about.documentation", "Documentation"),
                        systemImage: "book",
                        destination: "https://github.com/aeptus/chau7/blob/main/README.md"
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.link)
            .controlSize(.small)

            SettingsButtonRow(buttons: [
                .init(title: L("settings.about.copySupportInfo", "Copy Support Info"), icon: "doc.on.doc") {
                    copySupportInfo()
                },
                .init(title: L("settings.about.revealInFinder", "Reveal Log in Finder"), icon: "folder") {
                    model.revealLogFile()
                }
            ])
            .settingsSearchAnchor("aboutSupportInfo")

            if let supportInfoMessage {
                SettingsHint(icon: "checkmark.circle", text: supportInfoMessage)
            }

            SettingsDivider()

            // Diagnostics
            SettingsSectionHeader(L("settings.about.diagnostics", "Diagnostics"), icon: "stethoscope", anchorID: "aboutDiagnostics")

            SettingsInfoRow(label: L("settings.about.application", "Application"), value: ProcessInfo.processInfo.processName, monospaced: true)
            SettingsInfoRow(label: L("settings.about.bundleId", "Bundle ID"), value: Bundle.main.bundleIdentifier ?? L("settings.about.notBundled", "Not bundled"), monospaced: true)
            SettingsInfoRow(label: L("settings.about.version", "Version"), value: bundleVersion, monospaced: true)
            SettingsInfoRow(label: L("settings.about.built", "Built"), value: buildDateString, monospaced: true)
            SettingsInfoRow(label: "macOS", value: ProcessInfo.processInfo.operatingSystemVersionString, monospaced: true)
            SettingsInfoRow(label: L("settings.about.architecture", "Architecture"), value: machineArchitecture, monospaced: true)
            SettingsInfoRow(label: L("settings.about.logPath", "Log Path"), value: model.logFilePath, monospaced: true)

            SettingsButtonRow(buttons: [
                .init(title: L("debug.surface.diagnostics.title", "Diagnostics"), icon: "stethoscope") {
                    DebugConsoleController.shared.show(surface: .diagnostics)
                }
            ])

            SettingsDivider()

            // Acknowledgments
            SettingsSectionHeader(L("settings.about.acknowledgments", "Acknowledgments"), icon: "heart", anchorID: "aboutAcknowledgments")

            SettingsDescription(text: L("settings.about.stackSummary", "Chau7 combines Swift, Rust, and Go components across the app, terminal backend, and local proxy."))
            SettingsDescription(text: L("settings.about.licenseSummary", "Open-source acknowledgments and third-party notice files are listed in Help > Technology, Licenses & Acknowledgments."))

            SettingsButtonRow(buttons: [
                .init(title: L("settings.about.openAcknowledgments", "Open Acknowledgments"), icon: "doc.text.magnifyingglass") {
                    AppDelegate.shared?.showTechnologyLicenses()
                }
            ])

            SettingsDescription(text: L("settings.about.copyright", "Copyright © 2024-2026 Aeptus. Licensed under AGPL 3.0."))
        }
    }

    private func copySupportInfo() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(supportInfo, forType: .string)
        supportInfoMessage = L("settings.about.supportInfoCopied", "Support info copied.")
    }

    private var supportInfo: String {
        [
            "Chau7 \(bundleVersion)",
            "Application: \(ProcessInfo.processInfo.processName)",
            "Bundle ID: \(Bundle.main.bundleIdentifier ?? L("settings.about.notBundled", "Not bundled"))",
            "Built: \(buildDateString)",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Architecture: \(machineArchitecture)",
            "Log: \(model.logFilePath)"
        ].joined(separator: "\n")
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
            return L("about.developmentBuild", "Development Build")
        }
    }

    private var buildDateString: String {
        guard let execURL = Bundle.main.executableURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: execURL.path),
              let date = attrs[.modificationDate] as? Date else {
            return L("about.unknown", "Unknown")
        }
        let fmt = DateFormatter()
        fmt.locale = LocalizationManager.shared.currentLanguage.locale
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }

    private var machineArchitecture: String {
        #if arch(arm64)
        return L("about.arch.arm64", "Apple Silicon (arm64)")
        #elseif arch(x86_64)
        return L("about.arch.x86_64", "Intel (x86_64)")
        #else
        return L("about.unknown", "Unknown")
        #endif
    }

    private func aboutLink(title: String, systemImage: String, destination: String) -> some View {
        Link(destination: aboutURL(destination)) {
            Label(title, systemImage: systemImage)
        }
    }

    private func aboutURL(_ destination: String) -> URL {
        guard let url = URL(string: destination) else {
            assertionFailure("Invalid About settings URL: \(destination)")
            return URL(fileURLWithPath: "/")
        }
        return url
    }
}
