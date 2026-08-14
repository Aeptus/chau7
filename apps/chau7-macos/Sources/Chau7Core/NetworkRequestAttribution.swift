import Foundation

public struct NetworkRequestAttribution: Equatable, Sendable {
    public let component: String
    public let host: String

    public init(component: String, url: URL) {
        self.component = component
        host = url.host?.lowercased() ?? "unknown"
    }

    /// Intentionally excludes path, query, credentials, and fragments.
    public var logFields: String {
        "component=\(component) host=\(host)"
    }
}
