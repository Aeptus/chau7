import Foundation

/// Deep link actions from Live Activity buttons and notifications.
///
/// URL scheme: `chau7remote://`
/// - `open?tab_id=N` — open app, optionally switch to tab
/// - `switch?tab_id=N` — switch to a specific tab
/// - `review?request_id=X` — show that pending approval in the app
///
/// A link never answers an approval by itself: any app or web page can open
/// a custom-scheme URL, and a lock-screen tap would skip the hold-to-confirm
/// gate on destructive commands. The legacy `approve` and `deny` hosts, which
/// a Live Activity started by an older build may still show, therefore also
/// map to `review`.
public enum RemoteActivityURLAction: Equatable, Sendable {
    case open(tabID: UInt32?)
    case switchTab(tabID: UInt32)
    case review(requestID: String)

    public init?(url: URL) {
        guard url.scheme == "chau7remote" else { return nil }

        let host = url.host?.lowercased() ?? ""
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        func value(for name: String) -> String? {
            queryItems.first(where: { $0.name == name })?.value
        }

        let tabID = value(for: "tab_id").flatMap(UInt32.init)
        let requestID = value(for: "request_id")

        switch host {
        case "open":
            self = .open(tabID: tabID)
        case "switch":
            guard let tabID else { return nil }
            self = .switchTab(tabID: tabID)
        case "review", "approve", "deny":
            guard let requestID, !requestID.isEmpty else { return nil }
            self = .review(requestID: requestID)
        default:
            return nil
        }
    }
}
