import SwiftUI
import AppKit

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
    var disabled: Bool = false

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
    }
}

// MARK: - Settings Slider

struct SettingsSlider: View {
    let label: String
    let help: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var format: String = "%.0f"
    var suffix: String = ""
    var width: CGFloat = 150
    var disabled: Bool = false

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
    }
}

// MARK: - Settings Stepper

struct SettingsStepper: View {
    let label: String
    let help: String?
    @Binding var value: Int
    let range: ClosedRange<Int>
    var suffix: String = ""
    var disabled: Bool = false

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
                Text("\(value)\(suffix)")
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 60, alignment: .trailing)
            }
            .disabled(disabled)

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Settings Text Field

struct SettingsTextField: View {
    let label: String
    let help: String?
    let placeholder: String
    @Binding var text: String
    var width: CGFloat = 200
    var monospaced: Bool = false
    var disabled: Bool = false
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

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Settings Number Field

struct SettingsNumberField: View {
    let label: String
    let help: String?
    @Binding var value: Int
    var width: CGFloat = 100
    var disabled: Bool = false
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
    var disabled: Bool = false

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
    }
}

// MARK: - Settings Info Row (read-only display)

struct SettingsInfoRow: View {
    let label: String
    let value: String
    var valueColor: Color = .primary
    var monospaced: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: SettingsLayout.controlSpacing) {
            Text(label)
                .frame(width: SettingsLayout.labelWidth, alignment: .leading)

            Text(value)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .foregroundStyle(valueColor)

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Settings Button Row

struct SettingsButtonRow: View {
    let buttons: [SettingsButton]
    var alignment: HorizontalAlignment = .leading

    struct SettingsButton: Identifiable {
        let id = UUID()
        let title: String
        var icon: String? = nil
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
    var action: (() -> Void)? = nil
    var actionLabel: String? = nil
    var actionIcon: String? = nil

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
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Settings Description Text

struct SettingsDescription: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
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
        }
        .padding(.vertical, 2)
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
            Text(name)
                .fontWeight(.medium)
            Spacer()
            Text(commands)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// Note: NotificationFilterToggle is defined in MainPanelView.swift with help parameter
