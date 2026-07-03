import Chau7Core
import Foundation

/// Owns the MCP + remote control + CTO integration domain: MCP server
/// enablement/limits/permissions/profiles, remote relay configuration, token
/// optimization mode, and CTO prefix/tab overrides.
///
/// Extracted from `FeatureSettings` (which forwards) following the
/// store-behind-facade pattern of the other settings domains. The one-time
/// RTK → CTO key migration runs in `init`, so this store must be created
/// before `TabDisplaySettingsStore` loads the migrated CTO indicator value.
@Observable
final class MCPRemoteSettingsStore {

    enum Keys {
        /// Token Optimization (CTO)
        static let tokenOptimizationMode = "cto.mode"
        // MCP
        static let mcpEnabled = "mcp.enabled"
        static let mcpMaxTabs = "mcp.maxTabs"
        static let mcpRequiresApproval = "mcp.requiresApproval"
        static let mcpShowTabIndicator = "mcp.showTabIndicator"
        static let mcpPermissionMode = "mcp.permissionMode"
        static let mcpAllowedCommands = "mcp.allowedCommands"
        static let mcpBlockedCommands = "mcp.blockedCommands"
        static let mcpProfiles = "mcp.profiles"
        // Remote Control
        static let remoteEnabled = "remote.enabled"
        static let remoteRelayURL = "remote.relayURL"
        // CTO Integration
        static let ctoEnabled = "feature.ctoEnabled"
        static let ctoPrefix = "feature.ctoPrefix"
        static let ctoTabOverrides = "feature.ctoTabOverrides"
    }

    @ObservationIgnored private let defaults: UserDefaults

    // MARK: - Token Optimization (CTO) Settings

    var tokenOptimizationMode: TokenOptimizationMode {
        didSet {
            defaults.set(tokenOptimizationMode.rawValue, forKey: Keys.tokenOptimizationMode)
            NotificationCenter.default.post(name: .tokenOptimizationModeChanged, object: nil)
        }
    }

    // MARK: - MCP Settings

    var mcpEnabled: Bool {
        didSet { defaults.set(mcpEnabled, forKey: Keys.mcpEnabled) }
    }

    var mcpMaxTabs: Int {
        didSet { defaults.set(mcpMaxTabs, forKey: Keys.mcpMaxTabs) }
    }

    var mcpRequiresApproval: Bool {
        didSet { defaults.set(mcpRequiresApproval, forKey: Keys.mcpRequiresApproval) }
    }

    var mcpShowTabIndicator: Bool {
        didSet { defaults.set(mcpShowTabIndicator, forKey: Keys.mcpShowTabIndicator) }
    }

    var mcpPermissionMode: MCPPermissionMode {
        didSet { defaults.set(mcpPermissionMode.rawValue, forKey: Keys.mcpPermissionMode) }
    }

    var mcpAllowedCommands: [String] {
        didSet { defaults.set(mcpAllowedCommands, forKey: Keys.mcpAllowedCommands) }
    }

    var mcpBlockedCommands: [String] {
        didSet { defaults.set(mcpBlockedCommands, forKey: Keys.mcpBlockedCommands) }
    }

    var mcpProfiles: [MCPProfile] {
        didSet {
            if let data = Persist.encodeLogged(mcpProfiles, context: "settings.mcpProfiles") {
                defaults.set(data, forKey: Keys.mcpProfiles)
            }
        }
    }

    // MARK: - Remote Control Settings

    var isRemoteEnabled: Bool {
        didSet {
            defaults.set(isRemoteEnabled, forKey: Keys.remoteEnabled)
            NotificationCenter.default.post(name: .remoteEnabledChanged, object: self)
        }
    }

    var remoteRelayURL: String {
        didSet {
            let trimmed = remoteRelayURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if remoteRelayURL != trimmed {
                remoteRelayURL = trimmed
                return
            }
            defaults.set(remoteRelayURL, forKey: Keys.remoteRelayURL)
            NotificationCenter.default.post(name: .remoteRelayURLChanged, object: self)
        }
    }

    // MARK: - CTO Integration

    var isCTOEnabled: Bool {
        didSet { defaults.set(isCTOEnabled, forKey: Keys.ctoEnabled) }
    }

    var ctoPrefix: String {
        didSet {
            let trimmed = ctoPrefix.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .newlines)
            if ctoPrefix != trimmed {
                ctoPrefix = trimmed
                return
            }
            defaults.set(ctoPrefix, forKey: Keys.ctoPrefix)
        }
    }

    var ctoTabOverrides: [String: Bool] {
        didSet { defaults.set(ctoTabOverrides, forKey: Keys.ctoTabOverrides) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // One-time migration: RTK → CTO UserDefaults keys
        if !defaults.bool(forKey: "cto.migrated.v1") {
            let migrations: [(old: String, new: String)] = [
                ("tabs.display.showRTKIndicator", TabDisplaySettingsStore.Keys.showTabCTOIndicator),
                ("rtk.mode", Keys.tokenOptimizationMode),
                ("feature.rtkEnabled", Keys.ctoEnabled),
                ("feature.rtkPrefix", Keys.ctoPrefix),
                ("feature.rtkTabOverrides", Keys.ctoTabOverrides)
            ]
            for (old, new) in migrations {
                if let value = defaults.object(forKey: old), defaults.object(forKey: new) == nil {
                    defaults.set(value, forKey: new)
                }
                defaults.removeObject(forKey: old)
            }
            defaults.set(true, forKey: "cto.migrated.v1")
        }

        // Token Optimization (default: off)
        if let modeRaw = defaults.string(forKey: Keys.tokenOptimizationMode),
           let mode = TokenOptimizationMode(rawValue: modeRaw) {
            self.tokenOptimizationMode = mode
        } else {
            self.tokenOptimizationMode = .off
        }

        // MCP (default: enabled, 4 tabs, no approval, indicator on)
        self.mcpEnabled = defaults.object(forKey: Keys.mcpEnabled) as? Bool ?? true
        self.mcpMaxTabs = defaults.object(forKey: Keys.mcpMaxTabs) as? Int ?? 4
        self.mcpRequiresApproval = defaults.object(forKey: Keys.mcpRequiresApproval) as? Bool ?? false
        self.mcpShowTabIndicator = defaults.object(forKey: Keys.mcpShowTabIndicator) as? Bool ?? true
        if let modeRaw = defaults.string(forKey: Keys.mcpPermissionMode),
           let mode = MCPPermissionMode(rawValue: modeRaw) {
            self.mcpPermissionMode = mode
        } else {
            self.mcpPermissionMode = .allowAll
        }
        self.mcpAllowedCommands = defaults.stringArray(forKey: Keys.mcpAllowedCommands) ?? []
        self.mcpBlockedCommands = defaults.stringArray(forKey: Keys.mcpBlockedCommands) ?? []
        let profileData = defaults.data(forKey: Keys.mcpProfiles)
        self.mcpProfiles = Persist.decodeLogged([MCPProfile].self, from: profileData, context: "mcp.profiles") ?? []

        // Remote Control (default: disabled)
        self.isRemoteEnabled = defaults.object(forKey: Keys.remoteEnabled) as? Bool ?? false
        self.remoteRelayURL = defaults.string(forKey: Keys.remoteRelayURL) ?? "wss://relay.chau7.sh/connect"

        // CTO Integration (default: disabled)
        self.isCTOEnabled = defaults.object(forKey: Keys.ctoEnabled) as? Bool ?? false
        self.ctoPrefix = defaults.string(forKey: Keys.ctoPrefix) ?? ""
        if let raw = defaults.dictionary(forKey: Keys.ctoTabOverrides) {
            self.ctoTabOverrides = raw.compactMapValues { value in
                guard let boolValue = value as? Bool else { return nil }
                return boolValue
            }
        } else {
            self.ctoTabOverrides = [:]
        }
    }

    /// Reset by deriving from the loader (single source of defaults). The
    /// "cto.migrated.v1" flag is deliberately left in place — it records a
    /// completed migration, not a user setting.
    func resetToDefaults() {
        for key in [
            Keys.tokenOptimizationMode, Keys.mcpEnabled, Keys.mcpMaxTabs,
            Keys.mcpRequiresApproval, Keys.mcpShowTabIndicator,
            Keys.mcpPermissionMode, Keys.mcpAllowedCommands,
            Keys.mcpBlockedCommands, Keys.mcpProfiles, Keys.remoteEnabled,
            Keys.remoteRelayURL, Keys.ctoEnabled, Keys.ctoPrefix,
            Keys.ctoTabOverrides
        ] {
            defaults.removeObject(forKey: key)
        }
        let fresh = MCPRemoteSettingsStore(defaults: defaults)
        tokenOptimizationMode = fresh.tokenOptimizationMode
        mcpEnabled = fresh.mcpEnabled
        mcpMaxTabs = fresh.mcpMaxTabs
        mcpRequiresApproval = fresh.mcpRequiresApproval
        mcpShowTabIndicator = fresh.mcpShowTabIndicator
        mcpPermissionMode = fresh.mcpPermissionMode
        mcpAllowedCommands = fresh.mcpAllowedCommands
        mcpBlockedCommands = fresh.mcpBlockedCommands
        mcpProfiles = fresh.mcpProfiles
        isRemoteEnabled = fresh.isRemoteEnabled
        remoteRelayURL = fresh.remoteRelayURL
        isCTOEnabled = fresh.isCTOEnabled
        ctoPrefix = fresh.ctoPrefix
        ctoTabOverrides = fresh.ctoTabOverrides
    }
}
