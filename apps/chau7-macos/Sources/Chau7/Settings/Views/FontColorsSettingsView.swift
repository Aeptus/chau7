import SwiftUI
import AppKit

// MARK: - Font & Colors Settings

struct FontColorsSettingsView: View {
    @ObservedObject private var settings = FeatureSettings.shared
    @State private var customFontInput = ""
    @State private var customFontValid: Bool? // nil = not yet validated

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Live Preview Panel
            SettingsSectionHeader(L("settings.appearance.livePreview", "Live Preview"), icon: "rectangle.inset.filled.and.cursorarrow")

            LiveTerminalPreview(settings: settings)
                .padding(.bottom, 8)

            Divider()
                .padding(.vertical, 8)

            // Font Settings
            SettingsSectionHeader(L("settings.appearance.font", "Font"), icon: "textformat")

            FontFamilyPicker(
                label: L("settings.appearance.fontFamily", "Font Family"),
                help: L("settings.appearance.fontFamily.help", "Choose a monospace font for the terminal"),
                selection: $settings.fontFamily,
                families: FeatureSettings.availableFonts
            )

            // Custom font entry — validates live as you type, applies on Enter
            HStack(spacing: 8) {
                Text(L("settings.appearance.customFont", "Custom Font"))
                    .frame(width: 120, alignment: .trailing)
                TextField(
                    L("settings.appearance.customFont.placeholder", "Font family name..."),
                    text: $customFontInput,
                    onCommit: {
                        let family = customFontInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !family.isEmpty, customFontValid == true else { return }
                        settings.customFontFamily = family
                        settings.fontFamily = family
                    }
                )
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
                .onAppear {
                    customFontInput = settings.customFontFamily
                    if !customFontInput.isEmpty {
                        customFontValid = NSFontManager.shared.font(withFamily: customFontInput, traits: [], weight: 5, size: 12) != nil
                    }
                }
                .onChange(of: customFontInput) { newValue in
                    let family = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if family.isEmpty {
                        customFontValid = nil
                    } else {
                        customFontValid = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 12) != nil
                    }
                }

                if let valid = customFontValid {
                    Image(systemName: valid ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(valid ? .green : .red)
                        .help(valid
                            ? L("settings.appearance.customFont.valid", "Font found — press Enter to apply")
                            : L("settings.appearance.customFont.invalid", "Font not found on this system"))
                }
            }

            SettingsStepper(
                label: L("settings.appearance.fontSize", "Font Size"),
                help: L("settings.appearance.fontSize.help", "Terminal font size in points (8-72)"),
                value: $settings.fontSize,
                range: 8 ... 72,
                suffix: " pt"
            )

            SettingsSlider(
                label: L("settings.appearance.defaultZoom", "Default Zoom"),
                help: L("settings.appearance.defaultZoom.help", "Scale new terminal sessions (50-200%)"),
                value: Binding(
                    get: { Double(settings.defaultZoomPercent) },
                    set: { settings.defaultZoomPercent = Int($0) }
                ),
                range: 50 ... 200,
                step: 5,
                format: "%.0f",
                suffix: "%"
            )

            SettingsToggle(
                label: L("settings.appearance.ligatures", "Font Ligatures"),
                help: L("settings.appearance.ligatures.help", "Render multi-character ligatures (=>, ->, === etc.) for fonts that support them (Fira Code, JetBrains Mono, Cascadia Code). Disable for monospace fonts without ligature tables."),
                isOn: $settings.enableLigatures
            )

            // Font Preview — use NSFont bridge for SF Mono (SwiftUI .custom() can't resolve it)
            Text(L("settings.appearance.fontPreview", "The quick brown fox jumps over the lazy dog"))
                .font(Font(TerminalFont.resolveFont(family: settings.fontFamily, size: CGFloat(settings.fontSize))))
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
                .padding(.vertical, 8)

            // Color Scheme
            SettingsSectionHeader(L("settings.appearance.colorScheme", "Color Scheme"), icon: "paintpalette")

            SettingsPicker(
                label: L("settings.appearance.scheme", "Scheme"),
                help: L("settings.appearance.scheme.help", "Choose a terminal color scheme preset"),
                selection: $settings.colorSchemeName,
                options: TerminalColorScheme.allPresets.map { (value: $0.name, label: $0.name) }
            )

            // Color Preview
            ColorSchemePreview(scheme: settings.currentColorScheme)
                .padding(.vertical, 8)

            Divider()
                .padding(.vertical, 8)

            // Window Transparency
            SettingsSectionHeader(L("settings.appearance.window", "Window"), icon: "square.on.square.dashed")

            SettingsSlider(
                label: L("settings.appearance.windowOpacity", "Window Opacity"),
                help: L("settings.appearance.windowOpacity.help", "Transparency level for terminal window (30-100%)"),
                value: Binding(
                    get: { settings.windowOpacity * 100 },
                    set: { settings.windowOpacity = $0 / 100 }
                ),
                range: 30 ... 100,
                step: 5,
                format: "%.0f",
                suffix: "%"
            )

            Divider()
                .padding(.vertical, 8)

            // Theme
            SettingsSectionHeader(L("settings.appearance.systemTheme", "System Theme"), icon: "circle.lefthalf.filled")

            SettingsPicker(
                label: L("settings.appearance.appearance", "Appearance"),
                help: L("settings.appearance.appearance.help", "Choose light, dark, or match system appearance"),
                selection: $settings.appTheme,
                options: AppTheme.allCases.map { (value: $0, label: $0.displayName) }
            )

            Divider()
                .padding(.vertical, 8)

            // Reset Button
            SettingsButtonRow(buttons: [
                .init(title: L("settings.fontColors.resetToDefaults", "Reset Font & Colors to Defaults"), style: .plain) {
                    settings.resetFontColorsToDefaults()
                }
            ], alignment: .trailing)
        }
    }
}

// MARK: - Font Family Picker (renders each name in its own font)

/// A popup button that displays each font family name rendered in its actual typeface.
/// Uses NSPopUpButton via NSViewRepresentable because SwiftUI's Picker strips custom
/// fonts from menu items — NSMenuItem.attributedTitle is the only way to get per-item fonts.
private struct FontFamilyPicker: View {
    let label: String
    let help: String?
    @Binding var selection: String
    let families: [String]

    var body: some View {
        HStack(alignment: .top, spacing: SettingsLayout.controlSpacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if let help {
                    Text(help)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: SettingsLayout.labelWidth, alignment: .leading)

            FontFamilyPopUpButton(selection: $selection, families: families)
                .frame(width: 150, height: 24)

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

/// NSViewRepresentable wrapping NSPopUpButton with attributed menu items.
private struct FontFamilyPopUpButton: NSViewRepresentable {
    @Binding var selection: String
    let families: [String]

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        button.font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))
        rebuildMenu(button)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let currentTitles = button.itemTitles
        if currentTitles != families {
            rebuildMenu(button)
        }
        if button.titleOfSelectedItem != selection {
            button.selectItem(withTitle: selection)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    private func rebuildMenu(_ button: NSPopUpButton) {
        button.removeAllItems()
        let menuFontSize: CGFloat = 13
        for family in families {
            let item = NSMenuItem()
            item.title = family
            let font = TerminalFont.resolveFont(family: family, size: menuFontSize)
            item.attributedTitle = NSAttributedString(
                string: family,
                attributes: [.font: font]
            )
            button.menu?.addItem(item)
        }
        button.selectItem(withTitle: selection)
    }

    final class Coordinator: NSObject {
        var selection: Binding<String>

        init(selection: Binding<String>) {
            self.selection = selection
        }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            if let title = sender.titleOfSelectedItem {
                selection.wrappedValue = title
            }
        }
    }
}
