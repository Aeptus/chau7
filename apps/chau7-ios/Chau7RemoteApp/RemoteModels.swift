// Data models for the remote control protocol.
//
// The wire payload schemas (handshake, tabs, approvals, client state,
// pending state, errors) live in `Chau7Core/Remote/RemoteWirePayloads.swift`
// — the single Swift source of truth shared with the macOS app. This file
// keeps iOS-local aliases, UI-facing models, and utilities.
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

enum RemoteTabOrdering {
    static func alphabetically(_ tabs: [RemoteTab]) -> [RemoteTab] {
        tabs.sorted { lhs, rhs in
            let lhsTitle = lhs.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let rhsTitle = rhs.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let comparison = lhsTitle.localizedStandardCompare(rhsTitle)
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
            return lhs.tabID < rhs.tabID
        }
    }
}

/// Normalizes tab-list snapshots before they enter observable UI state.
/// Wire order is incidental (and can change with Mac activity), while tab ID
/// and descriptor metadata are the semantic inventory presented by iOS.
enum RemoteTabInventory {
    static func canonicalized(_ tabs: [RemoteTab]) -> [RemoteTab] {
        tabs.sorted { $0.tabID < $1.tabID }
    }

    /// Returns a canonical replacement only when the semantic inventory
    /// changed. `nil` means the caller should preserve its existing array so
    /// SwiftUI does not invalidate an open tab picker for a duplicate frame.
    static func replacementIfChanged(
        current: [RemoteTab],
        incoming: [RemoteTab]
    ) -> [RemoteTab]? {
        let canonicalIncoming = canonicalized(incoming)
        return canonicalized(current) == canonicalIncoming ? nil : canonicalIncoming
    }
}

/// Keeps terminal layout updates from masquerading as user scroll input.
/// `UIScrollView` may call its delegate when `contentSize` or a programmatic
/// offset changes; forwarding those callbacks to the Rust terminal pins the
/// renderer to old scrollback even though the user was following live output.
enum RemoteTerminalScrollPolicy {
    static func shouldForwardUserScroll(
        isSynchronizing: Bool,
        isTracking: Bool,
        isDragging: Bool,
        isDecelerating: Bool
    ) -> Bool {
        !isSynchronizing && (isTracking || isDragging || isDecelerating)
    }

    static func displayOffset(
        contentHeight: Double,
        viewportHeight: Double,
        contentOffsetY: Double,
        cellHeight: Double,
        scrollbackRows: Int
    ) -> Int {
        guard cellHeight > 0, scrollbackRows > 0 else { return 0 }
        let maximumContentOffset = max(0, contentHeight - viewportHeight)
        let distanceFromBottom = max(0, maximumContentOffset - contentOffsetY)
        let rowOffset = Int((distanceFromBottom / cellHeight).rounded())
        return min(max(rowOffset, 0), scrollbackRows)
    }
}

/// Readiness of the remote tab inventory, deliberately separate from the
/// WebSocket/encryption connection status.
enum RemoteTabInventoryState: Equatable {
    case unavailable
    case syncing
    case ready

    var displayText: String {
        switch self {
        case .unavailable: return "Unavailable"
        case .syncing: return "Syncing…"
        case .ready: return "Up to date"
        }
    }
}

enum RemoteConnectionTrigger: String, Equatable {
    case manual
    case appAppear = "app_appear"
    case sceneActive = "scene_active"
    case pushWake = "push_wake"
    case urlAction = "url_action"
    case approvalDelivery = "approval_delivery"
    case reconnect
}

enum RemoteDisconnectTrigger: String, Equatable {
    case manual
    case connectionRestart = "connection_restart"
    case transportFailure = "transport_failure"
    case handshakeTimeout = "handshake_timeout"
    case backgroundExpiration = "background_expiration"
}

/// Pure ownership rules for connection attempts. Automatic callers coalesce
/// behind any open transport, while an explicit manual retry may replace a
/// wedged handshake. Only one delayed reconnect may exist at a time.
enum RemoteConnectionStartPolicy {
    static func shouldStartConnection(transportIsOpen: Bool, forceRestart: Bool) -> Bool {
        forceRestart || !transportIsOpen
    }

    static func shouldScheduleReconnect(
        hasScheduledReconnect: Bool,
        shouldReconnect: Bool,
        hasRemainingAttempts: Bool
    ) -> Bool {
        !hasScheduledReconnect && shouldReconnect && hasRemainingAttempts
    }
}

enum RemoteConnectionFailureClassifier {
    static func classify(_ reason: String?) -> String {
        guard let reason = reason?.lowercased(), !reason.isEmpty else { return "unknown" }
        if reason.contains("handshake_timeout") || reason.contains("timed out") || reason.contains("timeout") {
            return "timeout"
        }
        if reason.contains("certificate") || reason.contains("tls") || reason.contains("ssl") {
            return "transport_security"
        }
        if reason.contains("cancel") {
            return "cancelled"
        }
        if reason.contains("network") && (reason.contains("unavailable") || reason.contains("offline")) {
            return "network_unavailable"
        }
        if reason.contains("connection lost")
            || reason.contains("connection reset")
            || reason.contains("broken pipe") {
            return "connection_lost"
        }
        return "other"
    }
}

/// Protects operational evidence from high-volume, privacy-sensitive input
/// capture. Sensitive entries trim in batches to amortize the required JSONL
/// rewrite; the global cap is then enforced against the remaining timeline.
enum DiagnosticsRetentionPolicy {
    static let sensitiveCategories: Set = ["input", "keystroke"]

    static func removalIndexes(
        categories: [String],
        maxEntries: Int,
        sensitiveLimit: Int,
        sensitiveTarget: Int
    ) -> IndexSet {
        guard maxEntries >= 0,
              sensitiveLimit >= 0,
              sensitiveTarget >= 0,
              sensitiveTarget <= sensitiveLimit else {
            return IndexSet()
        }

        var removals = IndexSet()
        let sensitiveIndexes = categories.indices.filter {
            sensitiveCategories.contains(categories[$0])
        }
        if sensitiveIndexes.count > sensitiveLimit {
            let trimCount = sensitiveIndexes.count - sensitiveTarget
            for index in sensitiveIndexes.prefix(trimCount) {
                removals.insert(index)
            }
        }

        var remainingOverflow = categories.count - removals.count - maxEntries
        if remainingOverflow > 0 {
            for index in categories.indices where !removals.contains(index) {
                removals.insert(index)
                remainingOverflow -= 1
                if remainingOverflow == 0 { break }
            }
        }
        return removals
    }
}

struct RemoteIssueReportContext: Equatable {
    let appVersion: String
    let osVersion: String
    let deviceModel: String
    let connectionStatus: String
    let tabInventoryStatus: String
    let tabCount: Int
}

/// Pure Markdown composition for both direct submission and the share-sheet
/// fallback. Diagnostics are absent unless the caller explicitly supplies an
/// excerpt, keeping the default report free of terminal activity.
enum RemoteIssueReportComposer {
    static func markdown(
        description: String,
        contact: String,
        context: RemoteIssueReportContext,
        diagnostics: String?
    ) -> String {
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContact = contact.trimmingCharacters(in: .whitespacesAndNewlines)
        var sections = [
            "# Chau7 Remote issue",
            "## Description\n\n\(trimmedDescription)",
            "## Contact\n\n\(trimmedContact.isEmpty ? "Not provided" : trimmedContact)",
            """
            ## Environment

            - App version: \(context.appVersion)
            - iOS: \(context.osVersion)
            - Device: \(context.deviceModel)
            - Connection: \(context.connectionStatus)
            - Remote tabs: \(context.tabInventoryStatus)
            - Tab count: \(context.tabCount)
            """
        ]

        if let diagnostics = diagnostics?.trimmingCharacters(in: .whitespacesAndNewlines),
           !diagnostics.isEmpty {
            sections.append("## Recent diagnostics\n\n```text\n\(diagnostics)\n```")
        }

        return sections.joined(separator: "\n\n") + "\n"
    }
}

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

    var id: String {
        requestID
    }

    var isProtectedRemoteAction: Bool {
        flaggedCommand != command
    }

    var title: String {
        isProtectedRemoteAction ? "Protected Remote Action" : "Command Approval"
    }

    var subtitle: String? {
        isProtectedRemoteAction ? flaggedCommand : nil
    }
}

struct ApprovalHistoryEntry: Identifiable {
    let id = UUID()
    let command: String
    let flaggedCommand: String
    let approved: Bool
    let timestamp: Date

    var isProtectedRemoteAction: Bool {
        flaggedCommand != command
    }

    var title: String {
        isProtectedRemoteAction ? flaggedCommand : command
    }
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

    /// Translates a scraped arrow-navigation response — repeated up/down CSI
    /// sequences plus an optional trailing CR/LF — into semantic keys for the
    /// KEY_INPUT frame, where the Mac's encoder handles application-cursor
    /// mode correctly. Returns nil for anything that isn't pure navigation
    /// (digits, y/n tokens, free text), which must stay on the text path.
    static func semanticKeys(forNavigationResponse response: String) -> [RemoteKeyInputPayload.Key]? {
        RemotePromptResponse.navigationKeys(for: response)
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
