import Foundation

/// Authoritative MCP protocol compatibility policy shared by Chau7's server
/// boundary and diagnostics.
public enum MCPProtocolCompatibility {
    /// Newest finalized protocol revision implemented by Chau7.
    public static let preferredVersion = "2025-11-25"

    /// Finalized revisions Chau7 can serve without translating messages.
    /// Keep newest-first so diagnostics and compatibility errors are stable.
    public static let supportedVersions = [
        preferredVersion,
        "2025-06-18",
        "2024-11-05"
    ]

    /// MCP requires a server to echo a requested revision when it supports it.
    public static func negotiate(requestedVersion: String) -> String? {
        supportedVersions.contains(requestedVersion) ? requestedVersion : nil
    }
}
