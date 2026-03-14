import Foundation

enum RemoteActivityURLAction: Equatable {
    case open(tabID: UInt32?)
    case switchTab(tabID: UInt32)
    case approve(requestID: String, tabID: UInt32?)
    case deny(requestID: String, tabID: UInt32?)

    init?(url: URL) {
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
        case "approve":
            guard let requestID, !requestID.isEmpty else { return nil }
            self = .approve(requestID: requestID, tabID: tabID)
        case "deny":
            guard let requestID, !requestID.isEmpty else { return nil }
            self = .deny(requestID: requestID, tabID: tabID)
        default:
            return nil
        }
    }
}
