import SwiftUI

// MARK: - Editor Settings

struct EditorSettingsView: View {
    @State private var config = EditorConfig.load()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Font
            SettingsSectionHeader(L("settings.editor.font", "Font"), icon: "textformat")

            SettingsStepper(
                label: L("settings.editor.fontSize", "Font Size"),
                help: L("settings.editor.fontSize.help", "Editor font size in points (8-36)"),
                value: $config.fontSize,
                range: 8...36,
                suffix: " pt"
            )
            .onChange(of: config.fontSize) { _ in config.save() }

            Divider()
                .padding(.vertical, 8)

            // Indentation
            SettingsSectionHeader(L("settings.editor.indentation", "Indentation"), icon: "increase.indent")

            SettingsStepper(
                label: L("settings.editor.tabSize", "Tab Size"),
                help: L("settings.editor.tabSize.help", "Number of spaces per indentation level (2, 4, or 8)"),
                value: $config.tabSize,
                range: 2...8,
                suffix: " spaces"
            )
            .onChange(of: config.tabSize) { _ in config.save() }

            SettingsToggle(
                label: L("settings.editor.useSpaces", "Use Spaces for Tabs"),
                help: L("settings.editor.useSpaces.help", "Insert spaces instead of tab characters when pressing Tab"),
                isOn: $config.useSpacesForTabs
            )
            .onChange(of: config.useSpacesForTabs) { _ in config.save() }

            SettingsToggle(
                label: L("settings.editor.autoIndent", "Auto-Indent"),
                help: L("settings.editor.autoIndent.help", "Automatically match indentation of the previous line on Enter"),
                isOn: $config.autoIndent
            )
            .onChange(of: config.autoIndent) { _ in config.save() }

            Divider()
                .padding(.vertical, 8)

            // Display
            SettingsSectionHeader(L("settings.editor.display", "Display"), icon: "eye")

            SettingsToggle(
                label: L("settings.editor.wordWrap", "Word Wrap"),
                help: L("settings.editor.wordWrap.help", "Wrap long lines to fit the editor width"),
                isOn: $config.wordWrap
            )
            .onChange(of: config.wordWrap) { _ in config.save() }

            SettingsToggle(
                label: L("settings.editor.lineNumbers", "Line Numbers"),
                help: L("settings.editor.lineNumbers.help", "Show line numbers in the editor gutter"),
                isOn: $config.showLineNumbers
            )
            .onChange(of: config.showLineNumbers) { _ in config.save() }

            SettingsToggle(
                label: L("settings.editor.highlightCurrentLine", "Highlight Current Line"),
                help: L("settings.editor.highlightCurrentLine.help", "Visually highlight the line where the cursor is positioned"),
                isOn: $config.highlightCurrentLine
            )
            .onChange(of: config.highlightCurrentLine) { _ in config.save() }

            SettingsToggle(
                label: L("settings.editor.minimap", "Minimap"),
                help: L("settings.editor.minimap.help", "Show a minimap overview of the file on the right side"),
                isOn: $config.showMinimap
            )
            .onChange(of: config.showMinimap) { _ in config.save() }

            Divider()
                .padding(.vertical, 8)

            // Editing Assistance
            SettingsSectionHeader(L("settings.editor.assistance", "Editing Assistance"), icon: "wand.and.stars")

            SettingsToggle(
                label: L("settings.editor.bracketMatching", "Bracket Matching"),
                help: L("settings.editor.bracketMatching.help", "Highlight matching brackets, parentheses, and braces"),
                isOn: $config.bracketMatching
            )
            .onChange(of: config.bracketMatching) { _ in config.save() }

            Divider()
                .padding(.vertical, 8)

            // Theme
            SettingsSectionHeader(L("settings.editor.theme", "Theme"), icon: "paintpalette")

            SettingsPicker(
                label: L("settings.editor.editorTheme", "Editor Theme"),
                help: L("settings.editor.editorTheme.help", "Choose a color theme for the editor syntax highlighting"),
                selection: $config.theme,
                options: [
                    (value: "default", label: L("settings.editor.themeDefault", "Default")),
                    (value: "dark", label: L("settings.editor.themeDark", "Dark")),
                    (value: "light", label: L("settings.editor.themeLight", "Light")),
                    (value: "solarized", label: L("settings.editor.themeSolarized", "Solarized")),
                    (value: "monokai", label: L("settings.editor.themeMonokai", "Monokai")),
                ]
            )
            .onChange(of: config.theme) { _ in config.save() }

            Divider()
                .padding(.vertical, 8)

            // Reset Button
            SettingsButtonRow(buttons: [
                .init(title: L("settings.editor.resetToDefaults", "Reset Editor to Defaults"), style: .plain) {
                    config = .default
                    config.save()
                },
            ], alignment: .trailing)
        }
    }
}
