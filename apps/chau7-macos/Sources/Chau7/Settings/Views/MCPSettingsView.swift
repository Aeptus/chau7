import SwiftUI

struct MCPSettingsView: View {
    @ObservedObject private var settings = FeatureSettings.shared

    @State private var newAllowedCommand = ""
    @State private var newBlockedCommand = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader(L("settings.mcp.general", "General"), icon: "face.dashed")

            SettingsToggle(
                label: L("settings.mcp.enable", "Enable MCP"),
                help: L("settings.mcp.enable.help", "Allow MCP clients to control Chau7 tabs via the local socket"),
                isOn: $settings.mcpEnabled
            )

            SettingsToggle(
                label: L("settings.mcp.approval", "Require Approval"),
                help: L("settings.mcp.approval.help", "Show a confirmation dialog before MCP creates a new tab"),
                isOn: $settings.mcpRequiresApproval,
                disabled: !settings.mcpEnabled
            )

            SettingsSectionHeader(L("settings.mcp.limits", "Limits"), icon: "number.square")

            SettingsRow(L("settings.mcp.maxTabs", "Max MCP Tabs"), help: L("settings.mcp.maxTabs.help", "Maximum number of tabs an MCP client can create (1-50)")) {
                Stepper(value: $settings.mcpMaxTabs, in: 1...50) {
                    Text("\(settings.mcpMaxTabs)")
                        .monospacedDigit()
                        .frame(width: 30, alignment: .trailing)
                }
                .disabled(!settings.mcpEnabled)
            }

            // MARK: - Command Permissions

            SettingsSectionHeader(L("settings.mcp.permissions", "Command Permissions"), icon: "lock.shield")

            SettingsRow(L("settings.mcp.permissionMode", "Permission Mode"), help: L("settings.mcp.permissionMode.help", "Controls how MCP commands are filtered")) {
                Picker("", selection: $settings.mcpPermissionMode) {
                    ForEach(MCPPermissionMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!settings.mcpEnabled)
            }

            if settings.mcpPermissionMode != .allowAll {
                commandListSection(
                    title: L("settings.mcp.allowedCommands", "Allowed Commands"),
                    help: L("settings.mcp.allowedCommands.help", "Commands that run immediately without prompting"),
                    commands: $settings.mcpAllowedCommands,
                    newCommand: $newAllowedCommand,
                    placeholder: "e.g. git, ls, cat"
                )

                commandListSection(
                    title: L("settings.mcp.blockedCommands", "Blocked Commands"),
                    help: L("settings.mcp.blockedCommands.help", "Commands that are always rejected — never execute"),
                    commands: $settings.mcpBlockedCommands,
                    newCommand: $newBlockedCommand,
                    placeholder: "e.g. rm, sudo, curl"
                )

                Text("Commands not in either list will prompt for approval.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // MARK: - Appearance

            SettingsSectionHeader(L("settings.mcp.appearance", "Appearance"), icon: "paintpalette")

            SettingsToggle(
                label: L("settings.mcp.indicator", "Show Tab Indicator"),
                help: L("settings.mcp.indicator.help", "Display a purple icon and background on MCP-created tabs"),
                isOn: $settings.mcpShowTabIndicator
            )
        }
    }

    @ViewBuilder
    private func commandListSection(
        title: String,
        help: String,
        commands: Binding<[String]>,
        newCommand: Binding<String>,
        placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))

            // Tag-style chips for existing commands
            if !commands.wrappedValue.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(commands.wrappedValue, id: \.self) { cmd in
                        HStack(spacing: 4) {
                            Text(cmd)
                                .font(.system(.caption, design: .monospaced))
                            Button(action: {
                                commands.wrappedValue.removeAll { $0 == cmd }
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.12))
                        .cornerRadius(6)
                    }
                }
            }

            // Add new command
            HStack(spacing: 6) {
                TextField(placeholder, text: newCommand)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit {
                        addCommand(to: commands, from: newCommand)
                    }
                Button("Add") {
                    addCommand(to: commands, from: newCommand)
                }
                .disabled(newCommand.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.leading, 4)
    }

    private func addCommand(to list: Binding<[String]>, from text: Binding<String>) {
        let trimmed = text.wrappedValue.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty, !list.wrappedValue.contains(trimmed) else {
            text.wrappedValue = ""
            return
        }
        list.wrappedValue.append(trimmed)
        text.wrappedValue = ""
    }
}

/// Simple flow layout for tag chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private struct LayoutResult {
        var size: CGSize
        var positions: [CGPoint]
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> LayoutResult {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            totalHeight = y + rowHeight
        }

        return LayoutResult(size: CGSize(width: maxWidth, height: totalHeight), positions: positions)
    }
}
