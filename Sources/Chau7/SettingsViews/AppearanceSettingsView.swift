import SwiftUI
import AppKit

// MARK: - Appearance Settings

struct AppearanceSettingsView: View {
    @ObservedObject private var settings = FeatureSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Live Preview Panel (NEW)
            SettingsSectionHeader("Live Preview", icon: "rectangle.inset.filled.and.cursorarrow")

            LiveTerminalPreview(settings: settings)
                .padding(.bottom, 8)

            Divider()
                .padding(.vertical, 8)

            // Font Settings (NEW)
            SettingsSectionHeader("Font", icon: "textformat")

            SettingsPicker(
                label: "Font Family",
                help: "Choose a monospace font for the terminal",
                selection: $settings.fontFamily,
                options: FeatureSettings.availableFonts.map { (value: $0, label: $0) }
            )

            SettingsRow("Font Size", help: "Terminal font size in points (8-72)") {
                HStack {
                    Stepper(value: $settings.fontSize, in: 8...72) {
                        Text("\(settings.fontSize) pt")
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 60, alignment: .trailing)
                    }
                }
            }

            SettingsRow("Default Zoom", help: "Scale new terminal sessions (50-200%)") {
                HStack {
                    Slider(value: Binding(
                        get: { Double(settings.defaultZoomPercent) },
                        set: { settings.defaultZoomPercent = Int($0) }
                    ), in: 50...200, step: 5)
                        .frame(width: 150)
                    Text("\(settings.defaultZoomPercent)%")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 55, alignment: .trailing)
                }
            }

            // Font Preview
            Text("The quick brown fox jumps over the lazy dog")
                .font(.custom(settings.fontFamily, size: CGFloat(settings.fontSize)))
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
                .padding(.vertical, 8)

            // Color Scheme (NEW)
            SettingsSectionHeader("Color Scheme", icon: "paintpalette")

            SettingsPicker(
                label: "Scheme",
                help: "Choose a terminal color scheme preset",
                selection: $settings.colorSchemeName,
                options: TerminalColorScheme.allPresets.map { (value: $0.name, label: $0.name) }
            )

            // Color Preview
            ColorSchemePreview(scheme: settings.currentColorScheme)
                .padding(.vertical, 8)

            Divider()
                .padding(.vertical, 8)

            // Window Transparency (NEW)
            SettingsSectionHeader("Window", icon: "square.on.square.dashed")

            SettingsRow("Window Opacity", help: "Transparency level for terminal window (30-100%)") {
                HStack {
                    Slider(value: $settings.windowOpacity, in: 0.3...1.0, step: 0.05)
                        .frame(width: 150)
                    Text("\(Int(settings.windowOpacity * 100))%")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 45, alignment: .trailing)
                }
            }

            Divider()
                .padding(.vertical, 8)

            // Theme
            SettingsSectionHeader("System Theme", icon: "circle.lefthalf.filled")

            SettingsPicker(
                label: "Appearance",
                help: "Choose light, dark, or match system appearance",
                selection: $settings.appTheme,
                options: AppTheme.allCases.map { (value: $0, label: $0.displayName) }
            )

            Divider()
                .padding(.vertical, 8)

            // AI Theming
            SettingsSectionHeader("AI Tab Theming", icon: "sparkles")

            SettingsToggle(
                label: "Auto Tab Themes",
                help: "Automatically color tabs based on the detected AI CLI (Claude = purple, Codex = green, etc.)",
                isOn: $settings.isAutoTabThemeEnabled
            )

            Divider()
                .padding(.vertical, 8)

            // Display Enhancements
            SettingsSectionHeader("Display Enhancements", icon: "eye")

            SettingsToggle(
                label: "Syntax Highlighting",
                help: "Highlight code syntax in terminal output for better readability",
                isOn: $settings.isSyntaxHighlightEnabled
            )

            SettingsToggle(
                label: "Clickable URLs",
                help: "Make URLs in terminal output clickable to open in browser",
                isOn: $settings.isClickableURLsEnabled
            )

            SettingsToggle(
                label: "Inline Images",
                help: "Display images inline using iTerm2's imgcat protocol (use imgcat command)",
                isOn: $settings.isInlineImagesEnabled
            )

            SettingsToggle(
                label: "Pretty Print JSON",
                help: "Automatically format JSON output with indentation and colors",
                isOn: $settings.isJSONPrettyPrintEnabled
            )

            SettingsToggle(
                label: "Line Timestamps",
                help: "Show timestamps next to each terminal line",
                isOn: $settings.isLineTimestampsEnabled
            )

            if settings.isLineTimestampsEnabled {
                SettingsTextField(
                    label: "Timestamp Format",
                    help: "Date format string (e.g., HH:mm:ss, yyyy-MM-dd HH:mm)",
                    placeholder: "HH:mm:ss",
                    text: $settings.timestampFormat,
                    width: 150,
                    monospaced: true
                )
            }

            Divider()
                .padding(.vertical, 8)

            // Reset Button
            HStack {
                Spacer()
                Button("Reset Appearance to Defaults") {
                    settings.resetAppearanceToDefaults()
                }
                .foregroundColor(.red)
            }
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
