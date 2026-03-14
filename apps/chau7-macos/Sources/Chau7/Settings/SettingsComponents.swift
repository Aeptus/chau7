import SwiftUI
import AppKit
import Chau7Core

// MARK: - Settings Layout Constants

enum SettingsLayout {
    static let labelWidth: CGFloat = 220
    static let controlSpacing: CGFloat = 16
}

// MARK: - Settings Section Header

struct SettingsSectionHeader: View {
    let title: String
    let icon: String?

    init(_ title: String, icon: String? = nil) {
        self.title = title
        self.icon = icon
    }

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.headline)
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

// MARK: - Generic Settings Row (for custom controls)

struct SettingsRow<Content: View>: View {
    let label: String
    let help: String?
    let content: () -> Content

    init(_ label: String, help: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.help = help
        self.content = content
    }

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

            content()

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Settings Toggle

struct SettingsToggle: View {
    let label: String
    let help: String
    @Binding var isOn: Bool
    var disabled = false

    var body: some View {
        HStack(alignment: .top, spacing: SettingsLayout.controlSpacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: SettingsLayout.labelWidth, alignment: .leading)

            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(disabled)

            Spacer()
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityHint(help)
        .accessibilityValue(isOn ? L("status.enabled", "Enabled") : L("status.disabled", "Disabled"))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Settings Slider

struct SettingsSlider: View {
    let label: String
    let help: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var format = "%.0f"
    var suffix = ""
    var width: CGFloat = 150
    var disabled = false

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

            HStack(spacing: 8) {
                Slider(value: $value, in: range, step: step)
                    .frame(width: width)
                    .disabled(disabled)
                Text(String(format: format, value) + suffix)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 50, alignment: .trailing)
                    .foregroundStyle(disabled ? .secondary : .primary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityHint(help ?? "")
        .accessibilityValue(String(format: format, value) + suffix)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                value = min(value + step, range.upperBound)
            case .decrement:
                value = max(value - step, range.lowerBound)
            @unknown default:
                break
            }
        }
    }
}

// MARK: - Settings Stepper

struct SettingsStepper: View {
    let label: String
    let help: String?
    @Binding var value: Int
    let range: ClosedRange<Int>
    var suffix = ""
    var disabled = false

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

            Stepper(value: $value, in: range) {
                Text(value.formatted() + suffix)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 60, alignment: .trailing)
            }
            .disabled(disabled)

            Spacer()
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityHint(help ?? "")
        .accessibilityValue(value.formatted() + suffix)
    }
}

// MARK: - Settings Text Field

struct SettingsTextField: View {
    let label: String
    let help: String?
    let placeholder: String
    @Binding var text: String
    var width: CGFloat = 200
    var monospaced = false
    var disabled = false
    var onSubmit: (() -> Void)?

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

            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
                .font(monospaced ? .system(size: 12, design: .monospaced) : .body)
                .disabled(disabled)
                .onSubmit { onSubmit?() }
                .accessibilityLabel(label)
                .accessibilityHint(help ?? "")

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Settings Directory Field

struct SettingsDirectoryField: View {
    let label: String
    let help: String?
    let placeholder: String
    @Binding var text: String
    var width: CGFloat = 200
    var monospaced = false
    var disabled = false
    var buttonTitle = "Choose..."
    var buttonIcon: String? = "folder"
    var onSubmit: (() -> Void)?

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

            HStack(spacing: 8) {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: width)
                    .font(monospaced ? .system(size: 12, design: .monospaced) : .body)
                    .disabled(disabled)
                    .onSubmit { onSubmit?() }
                    .accessibilityLabel(label)
                    .accessibilityHint(help ?? "")

                Button(action: chooseDirectory) {
                    if let buttonIcon {
                        Label(buttonTitle, systemImage: buttonIcon)
                    } else {
                        Text(buttonTitle)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(disabled)
                .accessibilityLabel(buttonTitle)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.prompt = buttonTitle.replacingOccurrences(of: "...", with: "")

        if let directoryURL = currentDirectoryURL() {
            panel.directoryURL = directoryURL
        }

        if panel.runModal() == .OK, let url = panel.url {
            text = compactPath(url.path)
        }
    }

    private func currentDirectoryURL() -> URL? {
        guard !text.isEmpty else { return nil }
        let expanded = RuntimeIsolation.expandTilde(in: text)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue {
            return URL(fileURLWithPath: expanded)
        }
        return nil
    }

    private func compactPath(_ path: String) -> String {
        let home = RuntimeIsolation.homePath()
        if path == home {
            return "~"
        }
        let homePrefix = home + "/"
        if path.hasPrefix(homePrefix) {
            return "~/" + String(path.dropFirst(homePrefix.count))
        }
        return path
    }
}

// MARK: - Settings Number Field

struct SettingsNumberField: View {
    let label: String
    let help: String?
    @Binding var value: Int
    var width: CGFloat = 100
    var disabled = false
    var onSubmit: (() -> Void)?

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

            TextField("", value: $value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
                .disabled(disabled)
                .onSubmit { onSubmit?() }
                .accessibilityLabel(label)
                .accessibilityHint(help ?? "")

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Settings Picker

struct SettingsPicker<T: Hashable>: View {
    let label: String
    let help: String?
    @Binding var selection: T
    let options: [(value: T, label: String)]
    var width: CGFloat = 150
    var disabled = false

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

            Picker("", selection: $selection) {
                ForEach(options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .labelsHidden()
            .frame(width: width)
            .disabled(disabled)

            Spacer()
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityHint(help ?? "")
        .accessibilityValue(options.first { $0.value == selection }?.label ?? "")
    }
}

// MARK: - Settings Info Row (read-only display)

struct SettingsInfoRow: View {
    let label: String
    let value: String
    var valueColor: Color = .primary
    var monospaced = false

    var body: some View {
        HStack(alignment: .top, spacing: SettingsLayout.controlSpacing) {
            Text(label)
                .frame(width: SettingsLayout.labelWidth, alignment: .leading)

            Text(value)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .foregroundStyle(valueColor)
                .textSelection(.enabled)

            Spacer()
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(format: L("accessibility.labelValue", "%@: %@"), label, value))
    }
}

// MARK: - Settings Button Row

struct SettingsButtonRow: View {
    let buttons: [SettingsButton]
    var alignment: HorizontalAlignment = .leading

    struct SettingsButton: Identifiable {
        let id = UUID()
        let title: String
        var icon: String?
        var style: ButtonType = .bordered
        var action: () -> Void

        enum ButtonType {
            case bordered, borderedProminent, plain
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            if alignment == .trailing {
                Spacer()
            }

            ForEach(buttons) { button in
                makeButton(button)
            }

            if alignment == .leading {
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func makeButton(_ button: SettingsButton) -> some View {
        let label: some View = {
            if let icon = button.icon {
                return AnyView(Label(button.title, systemImage: icon))
            } else {
                return AnyView(Text(button.title))
            }
        }()

        switch button.style {
        case .bordered:
            Button(action: button.action) { label }
                .buttonStyle(.bordered)
        case .borderedProminent:
            Button(action: button.action) { label }
                .buttonStyle(.borderedProminent)
        case .plain:
            Button(action: button.action) { label }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
        }
    }
}

// MARK: - Settings Card (featured section with action)

struct SettingsCard<Content: View>: View {
    let content: () -> Content
    var action: (() -> Void)?
    var actionLabel: String?
    var actionIcon: String?

    init(@ViewBuilder content: @escaping () -> Content, action: (() -> Void)? = nil, actionLabel: String? = nil, actionIcon: String? = nil) {
        self.content = content
        self.action = action
        self.actionLabel = actionLabel
        self.actionIcon = actionIcon
    }

    var body: some View {
        HStack {
            content()

            Spacer()

            if let action = action, let label = actionLabel {
                Button(action: action) {
                    if let icon = actionIcon {
                        Label(label, systemImage: icon)
                    } else {
                        Text(label)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}

// MARK: - Settings Hint (keyboard shortcut or tip)

struct SettingsHint: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Settings Description Text

struct SettingsDescription: View {
    let text: String

    init(text: String) {
        self.text = text
    }

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .padding(.vertical, 2)
    }
}

// MARK: - Settings Shortcut Row (keyboard shortcut display)

struct SettingsShortcutRow: View {
    let label: String
    let shortcut: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(shortcut)
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(4)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            String(
                format: L("accessibility.shortcutLabel", "%@, keyboard shortcut: %@"),
                label,
                shortcut
            )
        )
    }
}

// MARK: - Settings Detection Row (AI detection display)

struct SettingsDetectionRow: View {
    let name: String
    let commands: String
    let color: Color

    var body: some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            Text(name)
                .fontWeight(.medium)
            Spacer()
            Text(commands)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(format: L("accessibility.aiDetection", "%@ AI detection"), name))
        .accessibilityHint(String(format: L("accessibility.commands", "Commands: %@"), commands))
    }
}

// Note: NotificationFilterToggle is defined in NotificationsSettingsView.swift

// MARK: - Binding Helpers

extension Binding {
    /// Creates a binding to a nested property of a writable value.
    /// Eliminates the verbose `Binding(get:{ obj.prop }, set:{ var c = obj; c.prop = $0; obj = c })` pattern
    /// that arises from struct properties nested inside @Published.
    func nested<T>(_ keyPath: WritableKeyPath<Value, T>) -> Binding<T> {
        Binding<T>(
            get: { self.wrappedValue[keyPath: keyPath] },
            set: { self.wrappedValue[keyPath: keyPath] = $0 }
        )
    }

    /// Variant that clamps numeric values to a minimum bound on both read and write.
    /// Clamp-on-get ensures stale/invalid values from UserDefaults display correctly;
    /// clamp-on-set ensures new values are never stored below the floor.
    func nested<T: Comparable>(_ keyPath: WritableKeyPath<Value, T>, min minValue: T) -> Binding<T> {
        Binding<T>(
            get: { Swift.max(minValue, self.wrappedValue[keyPath: keyPath]) },
            set: { self.wrappedValue[keyPath: keyPath] = Swift.max(minValue, $0) }
        )
    }
}
