/// Data models for the remote control protocol.
///
/// The wire payload schemas (handshake, tabs, approvals, client state,
/// pending state, errors) live in `Chau7Core/Remote/RemoteWirePayloads.swift`
/// — the single Swift source of truth shared with the macOS app. This file
/// keeps iOS-local aliases, UI-facing models, and utilities.
import CryptoKit
import Chau7Core
import Foundation
import Security

// MARK: - Shared wire payload aliases
//
// Local names predate the Chau7Core consolidation; new code should use the
// Chau7Core names directly. These aliases disappear with the RemoteClient
// decomposition.

typealias PairingInfo = RemotePairingPayload
typealias HelloPayload = RemoteHelloPayload
typealias PairRequestPayload = RemotePairRequestPayload
typealias PairAcceptPayload = RemotePairAcceptPayload
typealias PairRejectPayload = RemotePairRejectPayload
typealias SessionReadyPayload = RemoteSessionReadyPayload
typealias TabListPayload = RemoteTabListPayload
typealias RemoteTab = RemoteTabDescriptor
typealias TabSwitchPayload = RemoteTabSwitchPayload

// MARK: - Pairing (iOS-local)

struct TrustedPairingIdentity: Codable, Equatable {
    let deviceID: String
    let macPub: String
    let iosPub: String

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case macPub = "mac_pub"
        case iosPub = "ios_pub"
    }
}

// MARK: - Approvals (UI-facing models)

enum ApprovalResponseState: Equatable {
    case idle
    case queued(Bool)
    case sending(Bool)

    var isBusy: Bool {
        switch self {
        case .idle:
            false
        case .queued, .sending:
            true
        }
    }

    var actionLabel: String? {
        switch self {
        case .idle:
            nil
        case .queued(true):
            "Queued Allow"
        case .queued(false):
            "Queued Deny"
        case .sending(true):
            "Sending Allow"
        case .sending(false):
            "Sending Deny"
        }
    }

    /// Whether the in-flight decision is an allow (true) or deny (false); nil
    /// when idle. Drives the in-flight banner's tint.
    var isAllowIntent: Bool? {
        switch self {
        case .idle:
            nil
        case let .queued(allow), let .sending(allow):
            allow
        }
    }
}

struct ApprovalRequest: Identifiable {
    let requestID: String
    let command: String
    let flaggedCommand: String
    let tabTitle: String?
    let toolName: String?
    let projectName: String?
    let branchName: String?
    let currentDirectory: String?
    let recentCommand: String?
    let contextNote: String?
    let sessionID: String?
    let timestamp: Date
    /// Authoritative risk tier — the Mac's `severity` wire value when present,
    /// otherwise `ApprovalSeverity.classify(...)` computed at decode time.
    let severity: ApprovalSeverity
    var responseState: ApprovalResponseState = .idle

    var id: String { requestID }
    var isProtectedRemoteAction: Bool { flaggedCommand != command }
    var title: String { isProtectedRemoteAction ? "Protected Remote Action" : "Command Approval" }
    var subtitle: String? { isProtectedRemoteAction ? flaggedCommand : nil }
}

struct ApprovalHistoryEntry: Identifiable {
    let id = UUID()
    let command: String
    let flaggedCommand: String
    let approved: Bool
    let timestamp: Date

    var isProtectedRemoteAction: Bool { flaggedCommand != command }
    var title: String { isProtectedRemoteAction ? flaggedCommand : command }
}

// MARK: - Notifications

/// Shared identifiers for local notifications, keeping category IDs, action IDs,
/// and `userInfo` keys in sync between the scheduler (`RemoteClient`) and the
/// handler (`AppDelegate`). Centralizing these avoids silent breakage from a
/// typo in one site that the other side never matches.
enum RemoteNotificationID {
    static let approvalCategory = "MCP_APPROVAL"
    static let interactivePromptCategory = "INTERACTIVE_PROMPT"

    enum Action {
        static let approve = "APPROVE"
        static let deny = "DENY"
    }

    enum UserInfoKey {
        static let requestID = "request_id"
        static let promptID = "prompt_id"
        static let tabID = "tab_id"
        static let openApprovals = "open_approvals"
        static let approved = "approved"
    }
}

// MARK: - Utilities

/// Shared JSON coders. `JSONEncoder`/`JSONDecoder` are expensive to allocate and
/// safe to reuse across calls; in this app they are only touched from the main
/// actor, so a single shared instance avoids per-frame/per-event allocation on
/// the hot paths (frame decode, telemetry, outbound payloads).
enum RemoteJSON {
    static let encoder = JSONEncoder()
    static let decoder = JSONDecoder()
}

enum CryptoUtils {
    static func randomBytes(count: Int) -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, baseAddress)
        }
        guard status == errSecSuccess else {
            fatalError("SecRandomCopyBytes failed with status \(status) — cannot generate secure random bytes")
        }
        return data
    }

    static func fingerprint(data: Data) -> String {
        Data(CryptoKit.SHA256.hash(data: data).prefix(8)).base64EncodedString()
    }
}

extension String {
    var strippingTrailingSlash: String {
        hasSuffix("/") ? String(dropLast()) : self
    }
}

// MARK: - Menu key heuristics

/// Pure decision logic for driving TUI selection menus from the phone.
/// Lives here (not on RemoteClient) so the host-less test bundle, which
/// compiles collaborator sources directly, can exercise it.
enum RemoteMenuKeyHeuristics {
    /// Whether the terminal view should surface the control key row without
    /// the user having pinned it: the active tab is showing a prompt card or
    /// reports it is waiting for input/approval, so esc/arrows/Return are the
    /// inputs the session actually needs right now.
    static func activeTabNeedsMenuKeys(
        prompts: [RemoteInteractivePrompt],
        activity: RemoteActivityState?,
        activeTabID: UInt32
    ) -> Bool {
        guard activeTabID != 0 else { return false }
        if prompts.contains(where: { $0.tabID == activeTabID }) {
            return true
        }
        guard let activity, activity.tabID == activeTabID else { return false }
        return activity.status == .waitingInput || activity.status == .approvalRequired
    }

    /// Whether a text-field send should drop its submit terminator. TUI menus
    /// act on a digit keypress immediately; the terminator would arrive as a
    /// separate delayed Enter and land on whatever renders next (e.g. silently
    /// answering the following question of a multi-question prompt). Gated on
    /// a pending prompt for the tab — not on activity status — so numeric
    /// free-text answers ("how many workers?") keep their Enter.
    static func shouldSuppressSubmitTerminator(
        text: String,
        hasPendingPromptForActiveTab: Bool
    ) -> Bool {
        hasPendingPromptForActiveTab
            && !text.isEmpty
            && text.count <= 3
            && text.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
