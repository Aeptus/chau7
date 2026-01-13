import SwiftUI
import AppKit

// MARK: - Appearance Settings

struct AppearanceSettingsView: View {
    @ObservedObject private var settings = FeatureSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Live Preview Panel (NEW)
            SettingsSectionHeader(L("settings.appearance.livePreview", "Live Preview"), icon: "rectangle.inset.filled.and.cursorarrow")

            LiveTerminalPreview(settings: settings)
                .padding(.bottom, 8)

            Divider()
                .padding(.vertical, 8)

            // Font Settings (NEW)
            SettingsSectionHeader(L("settings.appearance.font", "Font"), icon: "textformat")

            SettingsPicker(
                label: L("settings.appearance.fontFamily", "Font Family"),
                help: L("settings.appearance.fontFamily.help", "Choose a monospace font for the terminal"),
                selection: $settings.fontFamily,
                options: FeatureSettings.availableFonts.map { (value: $0, label: $0) }
            )

            SettingsStepper(
                label: L("settings.appearance.fontSize", "Font Size"),
                help: L("settings.appearance.fontSize.help", "Terminal font size in points (8-72)"),
                value: $settings.fontSize,
                range: 8...72,
                suffix: " pt"
            )

            SettingsSlider(
                label: L("settings.appearance.defaultZoom", "Default Zoom"),
                help: L("settings.appearance.defaultZoom.help", "Scale new terminal sessions (50-200%)"),
                value: Binding(
                    get: { Double(settings.defaultZoomPercent) },
                    set: { settings.defaultZoomPercent = Int($0) }
                ),
                range: 50...200,
                step: 5,
                format: "%.0f",
                suffix: "%"
            )

            // Font Preview
            Text(L("settings.appearance.fontPreview", "The quick brown fox jumps over the lazy dog"))
                .font(.custom(settings.fontFamily, size: CGFloat(settings.fontSize)))
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
                .padding(.vertical, 8)

            // Color Scheme (NEW)
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

            // Window Transparency (NEW)
            SettingsSectionHeader(L("settings.appearance.window", "Window"), icon: "square.on.square.dashed")

            SettingsSlider(
                label: L("settings.appearance.windowOpacity", "Window Opacity"),
                help: L("settings.appearance.windowOpacity.help", "Transparency level for terminal window (30-100%)"),
                value: Binding(
                    get: { settings.windowOpacity * 100 },
                    set: { settings.windowOpacity = $0 / 100 }
                ),
                range: 30...100,
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

            // AI Theming
            SettingsSectionHeader(L("settings.appearance.aiTabTheming", "AI Tab Theming"), icon: "sparkles")

            SettingsToggle(
                label: L("settings.appearance.autoTabThemes", "Auto Tab Themes"),
                help: L("settings.appearance.autoTabThemes.help", "Automatically color tabs based on the detected AI CLI (Claude = purple, Codex = green, etc.)"),
                isOn: $settings.isAutoTabThemeEnabled
            )

            Divider()
                .padding(.vertical, 8)

            // Display Enhancements
            SettingsSectionHeader(L("settings.appearance.displayEnhancements", "Display Enhancements"), icon: "eye")

            SettingsToggle(
                label: L("settings.appearance.syntaxHighlighting", "Syntax Highlighting"),
                help: L("settings.appearance.syntaxHighlighting.help", "Highlight code syntax in terminal output for better readability"),
                isOn: $settings.isSyntaxHighlightEnabled
            )

            SettingsToggle(
                label: L("settings.appearance.clickableURLs", "Clickable URLs"),
                help: L("settings.appearance.clickableURLs.help", "Make URLs in terminal output clickable to open in browser"),
                isOn: $settings.isClickableURLsEnabled
            )

            SettingsToggle(
                label: L("settings.appearance.inlineImages", "Inline Images"),
                help: L("settings.appearance.inlineImages.help", "Display images inline using iTerm2's imgcat protocol (use imgcat command)"),
                isOn: $settings.isInlineImagesEnabled
            )

            SettingsToggle(
                label: L("settings.appearance.prettyPrintJSON", "Pretty Print JSON"),
                help: L("settings.appearance.prettyPrintJSON.help", "Automatically format JSON output with indentation and colors"),
                isOn: $settings.isJSONPrettyPrintEnabled
            )

            SettingsToggle(
                label: L("settings.appearance.lineTimestamps", "Line Timestamps"),
                help: L("settings.appearance.lineTimestamps.help", "Show timestamps next to each terminal line"),
                isOn: $settings.isLineTimestampsEnabled
            )

            if settings.isLineTimestampsEnabled {
                SettingsTextField(
                    label: L("settings.appearance.timestampFormat", "Timestamp Format"),
                    help: L("settings.appearance.timestampFormat.help", "Date format string (e.g., HH:mm:ss, yyyy-MM-dd HH:mm)"),
                    placeholder: "HH:mm:ss",
                    text: $settings.timestampFormat,
                    width: 150,
                    monospaced: true
                )
            }

            Divider()
                .padding(.vertical, 8)

            // Reset Button
            SettingsButtonRow(buttons: [
                .init(title: L("settings.appearance.resetToDefaults", "Reset Appearance to Defaults"), style: .plain) {
                    settings.resetAppearanceToDefaults()
                }
            ], alignment: .trailing)
        }
    }
}

// MARK: - Color Scheme Preview

struct ColorSchemePreview: View {
    let scheme: TerminalColorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Background with foreground text
            HStack(spacing: 0) {
                Text("user@host:~ $ ")
                    .foregroundColor(Color(scheme.nsColor(for: scheme.green)))
                Text("ls -la")
                    .foregroundColor(Color(scheme.nsColor(for: scheme.foreground)))
            }
            .font(.system(size: 12, design: .monospaced))

            // Color palette preview
            HStack(spacing: 4) {
                ForEach([
                    scheme.black, scheme.red, scheme.green, scheme.yellow,
                    scheme.blue, scheme.magenta, scheme.cyan, scheme.white
                ], id: \.self) { hex in
                    Rectangle()
                        .fill(Color(scheme.nsColor(for: hex)))
                        .frame(width: 20, height: 16)
                        .cornerRadius(2)
                }
            }
        }
        .padding(10)
        .background(Color(scheme.nsColor(for: scheme.background)))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Live Terminal Preview

struct LiveTerminalPreview: View {
    @ObservedObject var settings: FeatureSettings

    private var scheme: TerminalColorScheme { settings.currentColorScheme }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title bar
            HStack(spacing: 6) {
                // Traffic lights
                Circle().fill(Color.red.opacity(0.8)).frame(width: 10, height: 10)
                Circle().fill(Color.yellow.opacity(0.8)).frame(width: 10, height: 10)
                Circle().fill(Color.green.opacity(0.8)).frame(width: 10, height: 10)
                Spacer()
                Text("Terminal Preview — zsh")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))

            // Terminal content
            VStack(alignment: .leading, spacing: 3) {
                // Previous command
                terminalLine(prompt: "user@mac", path: "~/Projects", command: "ls -la")
                outputLine("total 32")
                outputLine("drwxr-xr-x  5 user  staff   160 Jan 11 14:30 .", dim: true)
                outputLine("drwxr-xr-x  8 user  staff   256 Jan 10 09:15 ..", dim: true)
                fileLine("-rw-r--r--", "main.swift", .cyan)
                fileLine("-rw-r--r--", "Package.swift", .cyan)
                dirLine("drwxr-xr-x", "Sources/", .blue)

                // Current command with cursor
                HStack(spacing: 0) {
                    terminalPrompt(user: "user@mac", path: "~/Projects")
                    cursor
                }
            }
            .padding(12)
            .background(Color(scheme.nsColor(for: scheme.background)).opacity(settings.windowOpacity))
        }
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
    }

    private func terminalLine(prompt: String, path: String, command: String) -> some View {
        HStack(spacing: 0) {
            terminalPrompt(user: prompt, path: path)
            Text(command)
                .foregroundColor(Color(scheme.nsColor(for: scheme.foreground)))
        }
    }

    private func terminalPrompt(user: String, path: String) -> some View {
        HStack(spacing: 0) {
            Text(user)
                .foregroundColor(Color(scheme.nsColor(for: scheme.green)))
            Text(":")
                .foregroundColor(Color(scheme.nsColor(for: scheme.foreground)))
            Text(path)
                .foregroundColor(Color(scheme.nsColor(for: scheme.blue)))
            Text("$ ")
                .foregroundColor(Color(scheme.nsColor(for: scheme.foreground)))
        }
        .font(.custom(settings.fontFamily, size: CGFloat(settings.fontSize) * 0.85))
    }

    private func outputLine(_ text: String, dim: Bool = false) -> some View {
        Text(text)
            .font(.custom(settings.fontFamily, size: CGFloat(settings.fontSize) * 0.85))
            .foregroundColor(Color(scheme.nsColor(for: dim ? scheme.brightBlack : scheme.foreground)))
    }

    private func fileLine(_ perms: String, _ name: String, _ nameColor: FileColor) -> some View {
        HStack(spacing: 0) {
            Text(perms + "  1 user  staff   1.2K  ")
                .foregroundColor(Color(scheme.nsColor(for: scheme.foreground)))
            Text(name)
                .foregroundColor(Color(scheme.nsColor(for: colorFor(nameColor))))
        }
        .font(.custom(settings.fontFamily, size: CGFloat(settings.fontSize) * 0.85))
    }

    private func dirLine(_ perms: String, _ name: String, _ nameColor: FileColor) -> some View {
        HStack(spacing: 0) {
            Text(perms + "  3 user  staff    96B  ")
                .foregroundColor(Color(scheme.nsColor(for: scheme.foreground)))
            Text(name)
                .foregroundColor(Color(scheme.nsColor(for: colorFor(nameColor))))
                .fontWeight(.semibold)
        }
        .font(.custom(settings.fontFamily, size: CGFloat(settings.fontSize) * 0.85))
    }

    private enum FileColor { case cyan, blue, green }

    private func colorFor(_ c: FileColor) -> String {
        switch c {
        case .cyan: return scheme.cyan
        case .blue: return scheme.blue
        case .green: return scheme.green
        }
    }

    @ViewBuilder
    private var cursor: some View {
        let cursorColor = Color(scheme.nsColor(for: scheme.cursor))

        switch settings.cursorStyle {
        case "block":
            Rectangle()
                .fill(cursorColor)
                .frame(width: CGFloat(settings.fontSize) * 0.6, height: CGFloat(settings.fontSize) * 0.85)
                .opacity(settings.cursorBlink ? 0.7 : 1.0)
        case "underline":
            Rectangle()
                .fill(cursorColor)
                .frame(width: CGFloat(settings.fontSize) * 0.6, height: 2)
                .offset(y: CGFloat(settings.fontSize) * 0.35)
        case "bar":
            Rectangle()
                .fill(cursorColor)
                .frame(width: 2, height: CGFloat(settings.fontSize) * 0.85)
        default:
            Rectangle()
                .fill(cursorColor)
                .frame(width: CGFloat(settings.fontSize) * 0.6, height: CGFloat(settings.fontSize) * 0.85)
        }
    }
}
