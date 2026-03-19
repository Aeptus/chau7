import Foundation
import Chau7Core

/// Three-tier command permission result.
enum MCPCommandVerdict {
    case allowed
    case blocked(command: String)
    case needsApproval(command: String)
}

/// The resolved set of MCP permissions to apply for a given command.
/// Either from a matched profile or from global settings.
struct ResolvedPermissions {
    let mode: MCPPermissionMode
    let allowedCommands: Set<String>
    let blockedCommands: Set<String>
    /// The profile that was matched, if any. Nil means global settings.
    let matchedProfile: MCPProfile?

    /// The profile ID to target when "Always Allow" persists a command.
    var profileID: UUID? {
        matchedProfile?.id
    }

    /// Display name for the approval dialog ("profile: MyProfile" or "global").
    var sourceName: String {
        if let profile = matchedProfile {
            return "profile: \(profile.name)"
        }
        return "global"
    }
}

/// Parses shell commands and checks them against the MCP permission rules.
///
/// Permission model (deny-by-default when `permissionMode == .allowlist`):
///   1. Allowed commands — execute immediately, no prompt
///   2. Blocked commands — hard reject, never execute
///   3. Everything else — either route to user for approval or deny, depending on mode
enum MCPCommandFilter {

    // MARK: - Permission Resolution

    /// Resolve which permissions apply for a given tab context.
    /// Searches MCP profiles for the best match; falls back to global settings.
    static func resolvePermissions(for context: MCPTabContext?) -> ResolvedPermissions {
        let settings = FeatureSettings.shared

        if let context = context {
            if let profile = settings.mcpProfiles.bestMatch(for: context) {
                return ResolvedPermissions(
                    mode: profile.permissionMode,
                    allowedCommands: Set(profile.allowedCommands.map { $0.lowercased() }),
                    blockedCommands: Set(profile.blockedCommands.map { $0.lowercased() }),
                    matchedProfile: profile
                )
            }
        }

        return ResolvedPermissions(
            mode: settings.mcpPermissionMode,
            allowedCommands: Set(settings.mcpAllowedCommands.map { $0.lowercased() }),
            blockedCommands: Set(settings.mcpBlockedCommands.map { $0.lowercased() }),
            matchedProfile: nil
        )
    }

    // MARK: - Command Checking

    /// Check a command using global settings (no profile context).
    static func check(_ command: String) -> MCPCommandVerdict {
        let permissions = resolvePermissions(for: nil)
        return check(command, permissions: permissions).verdict
    }

    /// Check a command with tab context for profile-aware filtering.
    /// Returns both the verdict and the resolved permissions (needed by enforceVerdict).
    static func check(_ command: String, context: MCPTabContext?) -> (verdict: MCPCommandVerdict, permissions: ResolvedPermissions) {
        let permissions = resolvePermissions(for: context)
        return check(command, permissions: permissions)
    }

    /// Core check logic against a specific set of permissions.
    private static func check(_ command: String, permissions: ResolvedPermissions) -> (verdict: MCPCommandVerdict, permissions: ResolvedPermissions) {
        let baseCommands = extractBaseCommands(command)

        for base in baseCommands {
            let normalized = normalizeCommand(base)

            // Check blocked first — blocked always wins
            if permissions.blockedCommands.contains(normalized) {
                return (.blocked(command: base), permissions)
            }

            // Explicit allowlist entries always pass.
            if permissions.allowedCommands.contains(normalized) {
                continue
            }

            switch permissions.mode {
            case .allowAll:
                continue
            case .allowlist:
                return (.blocked(command: base), permissions)
            case .askUnlisted:
                return (.needsApproval(command: base), permissions)
            case .auditOnly:
                // Allow execution but log for audit review
                Log.info("MCP audit: command '\(base)' allowed under audit-only mode (\(permissions.sourceName))")
                continue
            }
        }

        return (.allowed, permissions)
    }

    /// Check raw terminal input (from tab_send_input). More conservative:
    /// tries to extract a command if the input looks like one.
    static func checkRawInput(_ input: String) -> MCPCommandVerdict {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // If it's just control characters or short interactive input, allow
        if trimmed.count <= 2 { return .allowed }
        // If it doesn't end with newline, it's likely interactive (typing), allow
        if !input.hasSuffix("\n"), !input.hasSuffix("\r") { return .allowed }
        // Treat as a command
        return check(trimmed)
    }

    /// Check raw terminal input with tab context for profile-aware filtering.
    static func checkRawInput(_ input: String, context: MCPTabContext?) -> (verdict: MCPCommandVerdict, permissions: ResolvedPermissions) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackPermissions = resolvePermissions(for: context)
        if trimmed.count <= 2 { return (.allowed, fallbackPermissions) }
        if !input.hasSuffix("\n"), !input.hasSuffix("\r") { return (.allowed, fallbackPermissions) }
        return check(trimmed, context: context)
    }

    // MARK: - Parsing

    /// Split a command string on shell operators to get individual sub-commands.
    /// Handles: `|`, `&&`, `||`, `;`, `$()`, backticks.
    static func extractBaseCommands(_ command: String) -> [String] {
        // Split on shell operators: ; && || | — but not inside quotes
        var commands: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var escape = false
        var i = command.startIndex

        while i < command.endIndex {
            let c = command[i]

            if escape {
                current.append(c)
                escape = false
                i = command.index(after: i)
                continue
            }

            if c == "\\", !inSingle {
                escape = true
                current.append(c)
                i = command.index(after: i)
                continue
            }

            if c == "'", !inDouble {
                inSingle.toggle()
                current.append(c)
                i = command.index(after: i)
                continue
            }

            if c == "\"", !inSingle {
                inDouble.toggle()
                current.append(c)
                i = command.index(after: i)
                continue
            }

            if !inSingle, !inDouble {
                // Check two-char operators first
                let remaining = command[i...]
                if remaining.hasPrefix("&&") || remaining.hasPrefix("||") {
                    if !current.trimmingCharacters(in: .whitespaces).isEmpty {
                        commands.append(current.trimmingCharacters(in: .whitespaces))
                    }
                    current = ""
                    i = command.index(i, offsetBy: 2)
                    continue
                }
                if c == "|" || c == ";" {
                    if !current.trimmingCharacters(in: .whitespaces).isEmpty {
                        commands.append(current.trimmingCharacters(in: .whitespaces))
                    }
                    current = ""
                    i = command.index(after: i)
                    continue
                }
                // $( starts a subshell — treat what follows as new command
                if remaining.hasPrefix("$(") {
                    if !current.trimmingCharacters(in: .whitespaces).isEmpty {
                        commands.append(current.trimmingCharacters(in: .whitespaces))
                    }
                    current = ""
                    i = command.index(i, offsetBy: 2)
                    continue
                }
            }

            current.append(c)
            i = command.index(after: i)
        }

        let final = current.trimmingCharacters(in: .whitespaces)
        if !final.isEmpty {
            commands.append(final)
        }

        // Extract the first token (the actual command name) from each sub-command
        return commands.compactMap { firstToken($0) }
    }

    /// Extract the first whitespace-delimited token from a command string.
    /// Skips leading env assignments (FOO=bar) and common prefixes (sudo, command, env, nohup).
    private static func firstToken(_ cmd: String) -> String? {
        let tokens = cmd.split(separator: " ", maxSplits: 20, omittingEmptySubsequences: true).map(String.init)
        guard !tokens.isEmpty else { return nil }

        let passthrough = Set(["sudo", "command", "env", "nohup", "nice", "time", "exec"])

        for token in tokens {
            // Skip env assignments: VAR=value
            if token.contains("="), !token.hasPrefix("="), !token.hasPrefix("-") {
                continue
            }
            // Skip flags for prefixes like env -i
            if token.hasPrefix("-") { continue }
            let base = normalizeCommand(token)
            if passthrough.contains(base) { continue }
            return token
        }

        return tokens.first
    }

    /// Normalize a command to its base name — strip path, lowercase.
    static func normalizeCommand(_ cmd: String) -> String {
        // Strip path: /usr/bin/rm → rm, ./script.sh → script.sh
        let base = (cmd as NSString).lastPathComponent
        return base.lowercased()
    }
}
