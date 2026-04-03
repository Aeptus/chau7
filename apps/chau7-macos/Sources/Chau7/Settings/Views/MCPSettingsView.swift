import SwiftUI
import Chau7Core

struct MCPSettingsView: View {
    @Bindable private var settings = FeatureSettings.shared

    @State private var newAllowedCommand = ""
    @State private var newBlockedCommand = ""
    @State private var editingProfile: MCPProfile?
    @State private var isAddingProfile = false

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
                Stepper(value: $settings.mcpMaxTabs, in: 1 ... 50) {
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
            }

            commandListSection(
                title: L("settings.mcp.blockedCommands", "Blocked Commands"),
                help: L("settings.mcp.blockedCommands.help", "Commands that are always rejected — never execute"),
                commands: $settings.mcpBlockedCommands,
                newCommand: $newBlockedCommand,
                placeholder: "e.g. rm, sudo, curl"
            )

            switch settings.mcpPermissionMode {
            case .allowAll:
                Text(L("mcp.mode.allowAll.help", "All commands run immediately except those in the blocked list."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .allowlist:
                Text(L("mcp.mode.allowlist.help", "Only commands in the allowed list run. Unlisted commands are denied."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .askUnlisted:
                Text(L("mcp.mode.askUnlisted.help", "Commands not in either list will prompt for approval."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .auditOnly:
                Text(L("mcp.mode.auditOnly.help", "All commands run but unlisted ones are logged for audit review."))
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

            // MARK: - MCP Profiles

            SettingsSectionHeader(L("settings.mcp.profiles", "MCP Profiles"), icon: "person.crop.rectangle.stack")

            Text(L("settings.mcp.profiles.help", "Profiles override global permissions when their trigger matches the current tab context."))
                .font(.caption)
                .foregroundStyle(.secondary)

            if !settings.mcpProfiles.isEmpty {
                VStack(spacing: 4) {
                    ForEach(settings.mcpProfiles) { profile in
                        profileRow(profile)
                    }
                }
            }

            Button(action: { isAddingProfile = true }) {
                Label(L("settings.mcp.addProfile", "Add Profile"), systemImage: "plus")
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)
        }
        .sheet(isPresented: $isAddingProfile) {
            MCPProfileEditorView(profile: nil) { newProfile in
                settings.mcpProfiles.append(newProfile)
                isAddingProfile = false
            } onCancel: {
                isAddingProfile = false
            }
        }
        .sheet(item: $editingProfile) { profile in
            MCPProfileEditorView(profile: profile) { updated in
                if let idx = settings.mcpProfiles.firstIndex(where: { $0.id == updated.id }) {
                    settings.mcpProfiles[idx] = updated
                }
                editingProfile = nil
            } onCancel: {
                editingProfile = nil
            }
        }
    }

    // MARK: - Profile Row

    private func profileRow(_ profile: MCPProfile) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(profile.isEnabled ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text(profile.name)
                        .font(.subheadline.weight(.medium))
                }
                Text("\(profile.trigger.displaySummary) — \(profile.permissionMode.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("P\(profile.priority)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
            Button(action: { editingProfile = profile }) {
                Image(systemName: "pencil")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            Button(action: {
                settings.mcpProfiles.removeAll { $0.id == profile.id }
            }) {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(6)
    }

    // MARK: - Command List Section

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
                MCPCommandFlowLayout(spacing: 6) {
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
                Button(L("mcp.add", "Add")) {
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

// MARK: - Profile Editor

private struct MCPProfileEditorView: View {
    let profile: MCPProfile?
    let onSave: (MCPProfile) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var isEnabled = true
    @State private var permissionMode: MCPPermissionMode = .askUnlisted
    @State private var priority = 0
    @State private var allowedCommands: [String] = []
    @State private var blockedCommands: [String] = []
    @State private var newAllowed = ""
    @State private var newBlocked = ""

    // Trigger state
    @State private var triggerTypeIndex = 0
    @State private var triggerValue = ""
    @State private var triggerEnvKey = ""

    private let triggerTypes = ["Directory", "Git Repository", "SSH Host", "Process", "Environment Variable"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(profile == nil ? L("mcp.settings.newProfile", "New MCP Profile") : L("mcp.settings.editProfile", "Edit MCP Profile"))
                .font(.headline)

            TextField(L("placeholder.profileName", "Profile Name"), text: $name)
                .textFieldStyle(.roundedBorder)

            Toggle(L("mcp.settings.enabled", "Enabled"), isOn: $isEnabled)

            Stepper(String(format: L("mcp.settings.priority", "Priority: %d"), priority), value: $priority, in: 0 ... 100)

            Divider()

            // Trigger
            Text(L("mcp.settings.trigger", "Trigger")).font(.subheadline.weight(.medium))
            Picker(L("mcp.settings.type", "Type"), selection: $triggerTypeIndex) {
                ForEach(0 ..< triggerTypes.count, id: \.self) { i in
                    Text(triggerTypes[i]).tag(i)
                }
            }
            .pickerStyle(.segmented)

            if triggerTypeIndex == 4 {
                HStack {
                    TextField(L("placeholder.key", "Key"), text: $triggerEnvKey)
                        .textFieldStyle(.roundedBorder)
                    Text("=")
                    TextField(L("placeholder.value", "Value"), text: $triggerValue)
                        .textFieldStyle(.roundedBorder)
                }
            } else {
                TextField(triggerPlaceholder, text: $triggerValue)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            Divider()

            // Permission mode
            Text(L("mcp.settings.permissionMode", "Permission Mode")).font(.subheadline.weight(.medium))
            Picker("", selection: $permissionMode) {
                ForEach(MCPPermissionMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            // Command lists
            if permissionMode != .allowAll {
                profileCommandList(title: L("mcp.settings.allowedCommands", "Allowed Commands"), commands: $allowedCommands, newCommand: $newAllowed)
            }
            profileCommandList(title: L("mcp.settings.blockedCommands", "Blocked Commands"), commands: $blockedCommands, newCommand: $newBlocked)

            Divider()

            HStack {
                Spacer()
                Button(L("action.cancel", "Cancel")) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(L("action.save", "Save")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || triggerValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 460)
        .onAppear {
            if let p = profile {
                name = p.name
                isEnabled = p.isEnabled
                permissionMode = p.permissionMode
                priority = p.priority
                allowedCommands = p.allowedCommands
                blockedCommands = p.blockedCommands
                loadTrigger(p.trigger)
            }
        }
    }

    private var triggerPlaceholder: String {
        switch triggerTypeIndex {
        case 0: return "~/projects/myapp"
        case 1: return "my-repo"
        case 2: return "prod-server.example.com"
        case 3: return "node"
        default: return ""
        }
    }

    private func loadTrigger(_ trigger: ProfileSwitchTrigger) {
        switch trigger {
        case .directory(let path):
            triggerTypeIndex = 0
            triggerValue = path
        case .gitRepository(let name):
            triggerTypeIndex = 1
            triggerValue = name
        case .sshHost(let hostname):
            triggerTypeIndex = 2
            triggerValue = hostname
        case .processRunning(let name):
            triggerTypeIndex = 3
            triggerValue = name
        case .environmentVariable(let key, let value):
            triggerTypeIndex = 4
            triggerEnvKey = key
            triggerValue = value
        }
    }

    private func buildTrigger() -> ProfileSwitchTrigger {
        let v = triggerValue.trimmingCharacters(in: .whitespaces)
        switch triggerTypeIndex {
        case 0: return .directory(path: v)
        case 1: return .gitRepository(name: v)
        case 2: return .sshHost(hostname: v)
        case 3: return .processRunning(name: v)
        case 4: return .environmentVariable(key: triggerEnvKey.trimmingCharacters(in: .whitespaces), value: v)
        default: return .directory(path: v)
        }
    }

    private func save() {
        let result = MCPProfile(
            id: profile?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            isEnabled: isEnabled,
            trigger: buildTrigger(),
            permissionMode: permissionMode,
            allowedCommands: allowedCommands,
            blockedCommands: blockedCommands,
            priority: priority
        )
        onSave(result)
    }

    private func profileCommandList(title: String, commands: Binding<[String]>, newCommand: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.medium))
            if !commands.wrappedValue.isEmpty {
                MCPCommandFlowLayout(spacing: 4) {
                    ForEach(commands.wrappedValue, id: \.self) { cmd in
                        HStack(spacing: 2) {
                            Text(cmd).font(.system(.caption2, design: .monospaced))
                            Button(action: { commands.wrappedValue.removeAll { $0 == cmd } }) {
                                Image(systemName: "xmark.circle.fill").font(.caption2).foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12))
                        .cornerRadius(4)
                    }
                }
            }
            HStack(spacing: 4) {
                TextField(L("placeholder.command", "command"), text: newCommand)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .onSubmit { addCmd(to: commands, from: newCommand) }
                Button(L("action.add", "Add")) { addCmd(to: commands, from: newCommand) }
                    .font(.caption)
                    .disabled(newCommand.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func addCmd(to list: Binding<[String]>, from text: Binding<String>) {
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
struct MCPCommandFlowLayout: Layout {
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
            if x + size.width > maxWidth, x > 0 {
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
