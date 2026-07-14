import SwiftUI

// MARK: - General Settings

struct GeneralSettingsView: View {
    @Bindable private var settings = FeatureSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Chau7Style.Settings.pageSectionSpacing) {
            // Startup
            SettingsSectionHeader(L("settings.general.startup", "Startup"), icon: "power")

            SettingsToggle(
                label: L("settings.general.launchAtLogin", "Launch at Login"),
                help: L("settings.general.launchAtLogin.help", "Automatically start Chau7 when you log in to your Mac"),
                isOn: $settings.launchAtLogin
            )

            SettingsDirectoryField(
                label: L("settings.general.defaultDirectory", "Default Directory"),
                help: L("settings.general.defaultDirectory.help", "Starting directory for new terminal sessions"),
                placeholder: "~",
                text: $settings.defaultStartDirectory,
                width: 280,
                monospaced: true,
                buttonTitle: L("settings.general.defaultDirectory.choose", "Choose...")
            )

            SettingsDivider()

            // Language
            SettingsSectionHeader(L("settings.general.language", "Language"), icon: "globe", anchorID: "languageHeader")

            SettingsPicker(
                label: L("settings.general.language.label", "App Language"),
                help: L("settings.general.language.help", "Choose the language for the Chau7 interface"),
                selection: $settings.appLanguage,
                options: AppLanguage.allCases.map { (value: $0, label: $0.displayName) },
                anchorID: "language"
            )

            SettingsDescription(text: L("settings.general.language.note", "Some changes may require restarting the app"))

            SettingsDivider()

            SettingsAdvancedDisclosure(
                L("settings.configFile.title", "Config File"),
                icon: "doc.text",
                searchAnchorIDs: ["configFile"]
            ) {
                ConfigFileSettingsView(showsTitle: false)
            }
        }
    }
}
