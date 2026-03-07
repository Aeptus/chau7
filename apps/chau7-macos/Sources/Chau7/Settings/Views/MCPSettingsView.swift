import SwiftUI

struct MCPSettingsView: View {
    @ObservedObject private var settings = FeatureSettings.shared

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

            SettingsSectionHeader(L("settings.mcp.appearance", "Appearance"), icon: "paintpalette")

            SettingsToggle(
                label: L("settings.mcp.indicator", "Show Tab Indicator"),
                help: L("settings.mcp.indicator.help", "Display a purple icon and background on MCP-created tabs"),
                isOn: $settings.mcpShowTabIndicator
            )
        }
    }
}
