import SwiftUI
import AppKit
import Chau7Core

// MARK: - Settings Layout Constants

enum SettingsLayout {
    static let labelWidth: CGFloat = Chau7Style.Settings.labelWidth
    static let controlSpacing: CGFloat = Chau7Style.Settings.rowSpacing
    static let compactRowSpacing: CGFloat = Chau7Style.Settings.compactRowSpacing
    static let minimumControlWidth: CGFloat = Chau7Style.Control.minimumWidth
    static let settingsWindowMinWidth: CGFloat = Chau7Style.Settings.windowMinWidth
    static let settingsWindowMinHeight: CGFloat = Chau7Style.Settings.windowMinHeight
    static let sidebarMinWidth: CGFloat = Chau7Style.Settings.sidebarMinWidth
    static let sidebarIdealWidth: CGFloat = Chau7Style.Settings.sidebarIdealWidth
    static let sidebarMaxWidth: CGFloat = Chau7Style.Settings.sidebarMaxWidth
    static let detailMinWidth: CGFloat = Chau7Style.Settings.detailMinWidth
    static let detailIdealWidth: CGFloat = Chau7Style.Settings.detailIdealWidth
}

// MARK: - Settings Surface Structure

struct SettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.vertical, Chau7Style.Settings.separatorVerticalPadding)
            .accessibilityHidden(true)
    }
}

// MARK: - Adaptive Settings Row Foundation

private struct SettingsLabelBlock: View {
    let label: String
    let help: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Chau7Style.Spacing.xxxSmall) {
            Text(label)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let help {
                Text(help)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SettingsAdaptiveRow<Content: View>: View {
    let label: String
    let help: String?
    let content: () -> Content

    init(_ label: String, help: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.help = help
        self.content = content
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: SettingsLayout.controlSpacing) {
                SettingsLabelBlock(label: label, help: help)
                    .frame(width: SettingsLayout.labelWidth, alignment: .leading)
                content()
                    .controlSize(.small)
                    .layoutPriority(1)
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: SettingsLayout.compactRowSpacing) {
                SettingsLabelBlock(label: label, help: help)
                content()
                    .controlSize(.small)
                    .layoutPriority(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Chau7Style.Settings.rowVerticalPadding)
    }
}

private extension View {
    func settingsControlWidth(_ width: CGFloat) -> some View {
        frame(
            minWidth: min(SettingsLayout.minimumControlWidth, width),
            idealWidth: width,
            maxWidth: width
        )
    }
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
        HStack(spacing: Chau7Style.Spacing.xSmall) {
            if let icon {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, Chau7Style.Settings.sectionTopPadding)
        .padding(.bottom, Chau7Style.Settings.sectionBottomPadding)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
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
        SettingsAdaptiveRow(label, help: help) {
            content()
        }
    }
}

// MARK: - Settings Toggle

struct SettingsToggle: View {
    let label: String
    let help: String
    @Binding var isOn: Bool
    var disabled = false

    var body: some View {
        SettingsAdaptiveRow(label, help: help) {
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(disabled)
        }
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
        SettingsAdaptiveRow(label, help: help) {
            HStack(spacing: Chau7Style.Spacing.small) {
                Slider(value: $value, in: range, step: step)
                    .settingsControlWidth(width)
                    .disabled(disabled)
                Text(String(format: format, value) + suffix)
                    .font(.system(.callout, design: .monospaced))
                    .frame(width: 50, alignment: .trailing)
                    .foregroundStyle(disabled ? .secondary : .primary)
            }
        }
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
        SettingsAdaptiveRow(label, help: help) {
            Stepper(value: $value, in: range) {
                Text(value.formatted() + suffix)
                    .font(.system(.callout, design: .monospaced))
                    .frame(width: 60, alignment: .trailing)
            }
            .disabled(disabled)
        }
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
        SettingsAdaptiveRow(label, help: help) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .settingsControlWidth(width)
                .font(monospaced ? .system(size: 11, design: .monospaced) : .callout)
                .disabled(disabled)
                .onSubmit { onSubmit?() }
                .accessibilityLabel(label)
                .accessibilityHint(help ?? "")
        }
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
        SettingsAdaptiveRow(label, help: help) {
            ViewThatFits(in: .horizontal) {
                directoryControls(axis: .horizontal)
                directoryControls(axis: .vertical)
            }
        }
    }

    @ViewBuilder
    private func directoryControls(axis: Axis.Set) -> some View {
        let controls = Group {
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .settingsControlWidth(width)
                .font(monospaced ? .system(size: 11, design: .monospaced) : .callout)
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

        if axis == .horizontal {
            HStack(spacing: Chau7Style.Settings.inlineControlSpacing) { controls }
        } else {
            VStack(alignment: .leading, spacing: Chau7Style.Settings.inlineControlSpacing) { controls }
        }
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
        SettingsAdaptiveRow(label, help: help) {
            TextField("", value: $value, format: .number)
                .textFieldStyle(.roundedBorder)
                .settingsControlWidth(width)
                .disabled(disabled)
                .onSubmit { onSubmit?() }
                .accessibilityLabel(label)
                .accessibilityHint(help ?? "")
        }
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
        SettingsAdaptiveRow(label, help: help) {
            Picker("", selection: $selection) {
                ForEach(options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .labelsHidden()
            .settingsControlWidth(width)
            .disabled(disabled)
        }
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
        SettingsAdaptiveRow(label) {
            Text(value)
                .font(monospaced ? .system(.callout, design: .monospaced) : .callout)
                .foregroundStyle(valueColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(format: L("accessibility.labelValue", "%@: %@"), label, value))
    }
}

// MARK: - Settings Status Summary

enum SettingsStatusTone {
    case active
    case paused
    case enabled
    case disabled
    case neutral
    case warning

    var color: Color {
        switch self {
        case .active, .enabled:
            return .green
        case .paused, .disabled:
            return .secondary
        case .neutral:
            return .accentColor
        case .warning:
            return .orange
        }
    }
}

struct SettingsStatusItem: Identifiable {
    let id: String
    let label: String
    let value: String
    var detail: String?
    var systemImage: String
    var tone: SettingsStatusTone

    init(
        id: String,
        label: String,
        value: String,
        detail: String? = nil,
        systemImage: String,
        tone: SettingsStatusTone = .neutral
    ) {
        self.id = id
        self.label = label
        self.value = value
        self.detail = detail
        self.systemImage = systemImage
        self.tone = tone
    }
}

struct SettingsStatusGrid: View {
    let items: [SettingsStatusItem]
    var minimumColumnWidth: CGFloat = 165

    private var columns: [GridItem] {
        [
            GridItem(
                .adaptive(minimum: minimumColumnWidth),
                spacing: Chau7Style.Settings.inlineControlSpacing,
                alignment: .top
            )
        ]
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Chau7Style.Settings.inlineControlSpacing) {
            ForEach(items) { item in
                statusCell(item)
            }
        }
        .padding(Chau7Style.Settings.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(Chau7Style.Radius.medium)
    }

    private func statusCell(_ item: SettingsStatusItem) -> some View {
        HStack(alignment: .top, spacing: Chau7Style.Spacing.xSmall) {
            Image(systemName: item.systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(item.tone.color)
                .frame(width: 14, alignment: .center)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Chau7Style.Spacing.xxxSmall) {
                Text(item.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .firstTextBaseline, spacing: Chau7Style.Spacing.xxSmall) {
                    Circle()
                        .fill(item.tone.color)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(item.value)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(item.tone.color)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let detail = item.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(format: L("accessibility.labelValue", "%@: %@"), item.label, item.value))
        .accessibilityHint(item.detail ?? "")
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
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Chau7Style.Settings.looseControlSpacing) {
                if alignment == .trailing {
                    Spacer(minLength: 0)
                }

                ForEach(buttons) { button in
                    makeButton(button)
                }

                if alignment == .leading {
                    Spacer(minLength: 0)
                }
            }

            VStack(alignment: alignment, spacing: Chau7Style.Settings.inlineControlSpacing) {
                ForEach(buttons) { button in
                    makeButton(button)
                }
            }
            .frame(
                maxWidth: .infinity,
                alignment: alignment == .trailing ? .trailing : .leading
            )
        }
        .padding(.vertical, Chau7Style.Settings.rowVerticalPadding)
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
        ViewThatFits(in: .horizontal) {
            HStack {
                content()

                Spacer(minLength: Chau7Style.Spacing.medium)

                if let action = action, let label = actionLabel {
                    cardButton(action: action, label: label)
                }
            }

            VStack(alignment: .leading, spacing: Chau7Style.Settings.inlineControlSpacing) {
                content()

                if let action = action, let label = actionLabel {
                    cardButton(action: action, label: label)
                }
            }
        }
        .padding(Chau7Style.Settings.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(Chau7Style.Radius.medium)
    }

    @ViewBuilder
    private func cardButton(action: @escaping () -> Void, label: String) -> some View {
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

// MARK: - Settings Hint (keyboard shortcut or tip)

struct SettingsHint: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Chau7Style.Spacing.xSmall) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .padding(.top, Chau7Style.Spacing.xxxSmall)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Chau7Style.Spacing.xxxSmall)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
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
            .font(.caption2)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, Chau7Style.Spacing.xxxSmall)
    }
}

// MARK: - Settings Shortcut Row (keyboard shortcut display)

struct SettingsShortcutRow: View {
    let label: String
    let shortcut: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Chau7Style.Spacing.medium)
                shortcutBadge
            }

            VStack(alignment: .leading, spacing: Chau7Style.Spacing.xSmall) {
                Text(label)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                shortcutBadge
            }
        }
        .padding(.vertical, Chau7Style.Spacing.xxxSmall)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            String(
                format: L("accessibility.shortcutLabel", "%@, keyboard shortcut: %@"),
                label,
                shortcut
            )
        )
    }

    private var shortcutBadge: some View {
        Text(shortcut)
            .font(.system(.caption, design: .monospaced))
            .padding(.horizontal, Chau7Style.Spacing.small)
            .padding(.vertical, Chau7Style.Spacing.xxSmall)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(Chau7Style.Radius.xSmall)
            .textSelection(.enabled)
    }
}

// MARK: - Settings Detection Row (AI detection display)

struct SettingsDetectionRow: View {
    let name: String
    let commands: String
    let color: Color

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                nameLabel
                Spacer(minLength: Chau7Style.Spacing.medium)
                commandsText
            }

            VStack(alignment: .leading, spacing: Chau7Style.Spacing.xxSmall) {
                nameLabel
                commandsText
            }
        }
        .padding(.vertical, Chau7Style.Spacing.xxxSmall)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(format: L("accessibility.aiDetection", "%@ AI detection"), name))
        .accessibilityHint(String(format: L("accessibility.commands", "Commands: %@"), commands))
    }

    private var nameLabel: some View {
        HStack(spacing: Chau7Style.Spacing.xSmall) {
            Circle()
                .fill(color)
                .frame(width: Chau7Style.Control.statusDot, height: Chau7Style.Control.statusDot)
                .accessibilityHidden(true)
            Text(name)
                .fontWeight(.medium)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var commandsText: some View {
        Text(commands)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// Note: NotificationFilterToggle is defined in NotificationsSettingsView.swift

// MARK: - Binding Helpers

extension Binding {
    /// Creates a binding to a nested property of a writable value.
    /// Eliminates the verbose `Binding(get:{ obj.prop }, set:{ var c = obj; c.prop = $0; obj = c })` pattern
    /// that arises from struct properties nested inside @Observable state.
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
