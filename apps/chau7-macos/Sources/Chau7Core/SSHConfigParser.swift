import Foundation

/// Parsed entry from an SSH config file
public struct SSHConfigEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let host: String           // Host pattern
    public var hostname: String?      // HostName
    public var user: String?          // User
    public var port: Int?             // Port
    public var identityFile: String?  // IdentityFile
    public var proxyJump: String?     // ProxyJump
    public var forwardAgent: Bool?    // ForwardAgent
    public var extraOptions: [String: String]  // Everything else

    public init(
        id: UUID = UUID(),
        host: String,
        hostname: String? = nil,
        user: String? = nil,
        port: Int? = nil,
        identityFile: String? = nil,
        proxyJump: String? = nil,
        forwardAgent: Bool? = nil,
        extraOptions: [String: String] = [:]
    ) {
        self.id = id
        self.host = host
        self.hostname = hostname
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.proxyJump = proxyJump
        self.forwardAgent = forwardAgent
        self.extraOptions = extraOptions
    }

    /// Convert to display-friendly name
    public var displayName: String {
        if let hostname = hostname {
            if let user = user { return "\(user)@\(hostname)" }
            return hostname
        }
        return host
    }
}

/// Parser for OpenSSH config file format
public enum SSHConfigParser {

    /// Parse an SSH config file content into entries
    public static func parse(_ content: String) -> [SSHConfigEntry] {
        var entries: [SSHConfigEntry] = []
        var currentEntry: SSHConfigEntry?

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines and comments
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            // Split into key and value (SSH config supports both space and = separators)
            let parts: [String]
            if let eqRange = trimmed.range(of: "="), !trimmed[trimmed.startIndex..<eqRange.lowerBound].contains(" ") {
                // key=value or key = value (no spaces in key before =)
                let key = String(trimmed[trimmed.startIndex..<eqRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[eqRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                parts = [key, value]
            } else {
                parts = trimmed.split(separator: " ", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            }
            guard parts.count == 2 else { continue }

            let key = parts[0].lowercased()
            let value = parts[1]

            if key == "host" {
                // Save previous entry
                if let entry = currentEntry {
                    entries.append(entry)
                }
                // Start new entry
                currentEntry = SSHConfigEntry(host: value)
            } else if var entry = currentEntry {
                // Add option to current entry
                switch key {
                case "hostname": entry.hostname = value
                case "user": entry.user = value
                case "port": entry.port = Int(value)
                case "identityfile": entry.identityFile = value
                case "proxyjump": entry.proxyJump = value
                case "forwardagent": entry.forwardAgent = (value.lowercased() == "yes")
                default: entry.extraOptions[parts[0]] = value  // Preserve original case for key
                }
                currentEntry = entry
            }
        }

        // Don't forget the last entry
        if let entry = currentEntry {
            entries.append(entry)
        }

        return entries
    }

    /// Serialize entries back to SSH config format
    public static func serialize(_ entries: [SSHConfigEntry]) -> String {
        var lines: [String] = []

        for entry in entries {
            lines.append("Host \(entry.host)")
            if let v = entry.hostname { lines.append("    HostName \(v)") }
            if let v = entry.user { lines.append("    User \(v)") }
            if let v = entry.port { lines.append("    Port \(v)") }
            if let v = entry.identityFile { lines.append("    IdentityFile \(v)") }
            if let v = entry.proxyJump { lines.append("    ProxyJump \(v)") }
            if let v = entry.forwardAgent { lines.append("    ForwardAgent \(v ? "yes" : "no")") }
            for (k, v) in entry.extraOptions.sorted(by: { $0.key < $1.key }) {
                lines.append("    \(k) \(v)")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }
}
