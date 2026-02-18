import SwiftUI
import AppKit

// MARK: - Color Scheme Preview
// Used by FontColorsSettingsView

struct ColorSchemePreview: View {
    let scheme: TerminalColorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Background with foreground text
            HStack(spacing: 0) {
                Text(L("user@host:~ $ ", "user@host:~ $ "))
                    .foregroundColor(Color(scheme.nsColor(for: scheme.green)))
                Text(L("ls -la", "ls -la"))
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
// Used by FontColorsSettingsView

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
                Text(L("Terminal Preview — zsh", "Terminal Preview — zsh"))
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
            Text(L(":", ":"))
                .foregroundColor(Color(scheme.nsColor(for: scheme.foreground)))
            Text(path)
                .foregroundColor(Color(scheme.nsColor(for: scheme.blue)))
            Text(L("$ ", "$ "))
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
