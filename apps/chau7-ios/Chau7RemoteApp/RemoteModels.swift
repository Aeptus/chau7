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

/// Pure geometry for the rich terminal renderer's grid dimensions.
///
/// The render store cannot build a playback — and therefore cannot publish a
/// `renderState` — until it has been told how many columns/rows the viewport
/// holds. That declaration must therefore happen from a laid-out view
/// *regardless* of whether a `renderState` exists yet, or the renderer
/// deadlocks itself into never starting.
///
/// Lives here (not in the renderer view) so the host-less test bundle — which
/// compiles collaborators directly and cannot link the Rust terminal FFI or the
/// UIKit font stack — can exercise the size math directly.
enum RemoteTerminalViewportGeometry {
    /// Largest whole-cell grid that fits `available`, never smaller than 1×1.
    /// Returns nil for a degenerate size so callers can distinguish "not laid
    /// out yet" from "genuinely 1×1".
    static func gridSize(available: CGSize, cell: CGSize) -> (cols: Int, rows: Int)? {
        guard available.width > 0, available.height > 0 else { return nil }
        guard cell.width >= 1, cell.height >= 1 else { return nil }
        return (
            max(1, Int(floor(available.width / cell.width))),
            max(1, Int(floor(available.height / cell.height)))
        )
    }

    /// Pixel size for a host-rendered alternate screen. Its terminal grid is
    /// authoritative, so every source cell keeps its real dimensions and the
    /// scroll view pans over the full grid instead of folding rows to the phone.
    static func alternateScreenContentSize(
        cols: Int,
        rows: Int,
        cell: CGSize,
        viewport: CGSize
    ) -> CGSize? {
        guard cols > 0, rows > 0, cell.width >= 1, cell.height >= 1 else { return nil }
        guard viewport.width > 0, viewport.height > 0 else { return nil }
        return CGSize(
            width: max(viewport.width, CGFloat(cols) * cell.width),
            height: max(viewport.height, CGFloat(rows) * cell.height)
        )
    }
}

/// Re-composition of a terminal grid that is wider than the phone.
///
/// The Mac draws full-screen TUIs (Claude Code, Codex) at its own PTY width —
/// often 100+ columns. Sizing the iOS emulator to the *phone* instead made the
/// engine hard-wrap that output at ~40 columns, so every logical line arrived
/// already fragmented and the layout was scrambled before it was ever painted.
///
/// The fix separates the two widths:
///  * **ingest** happens at the source width (announced by the Mac), so the
///    engine reproduces the TUI faithfully with no hard-wrap; and
///  * **display** folds that wide grid down to the phone by re-wrapping each
///    source row across as many phone-width rows as it needs.
///
/// Only presentation wraps. The engine's row grid — cursor, scrollback,
/// alternate screen — is untouched, so a cursor-positioning TUI still lands in
/// the right cell, it is simply painted across the phone-width row that cell
/// falls in.
///
/// Lives here (not in the renderer view) so the host-less test bundle can
/// exercise the mapping directly.
/// Numbers needed to explain what the re-composition is doing to a frame.
///
/// Without these, a wrong-looking phone render can only be diagnosed by reading
/// the draw path: it is not visible anywhere that the eye can check. Rendered by
/// `RemoteTerminalCanvasView` when diagnostics are enabled.
struct RemoteTerminalRenderDiagnostics: Equatable {
    /// Engine grid width (the Mac's PTY width the output was ingested at).
    var sourceCols: Int = 0
    /// Engine grid height.
    var sourceRows: Int = 0
    /// Phone-width columns that fit on screen.
    var displayCols: Int = 0
    /// Phone-width rows the visible source rows fold into.
    var displayRows: Int = 0
    /// Engine rows retained in scrollback.
    var scrollbackRows: Int = 0
    /// Cells whose cluster bytes were decoded this frame. This is the cost that
    /// makes the current per-cell `clusterString` fold expensive; Phase 3
    /// should drive it to roughly the visible cell count once Rust pre-folds.
    var decodedCells: Int = 0
    /// Milliseconds spent inside the last `draw(_:)`.
    var drawMilliseconds: Double = 0
    /// Source rows that soft-wrap from the row above, as reported by the
    /// engine's wrap flag.
    var softWrappedRows: Int = 0
}

/// Maps a display row to its slice of the engine's folded cell buffer.
///
/// The engine hands back a flat cell array plus one start offset per row (with a
/// trailing sentinel). Getting this wrong paints the wrong cells on a row rather
/// than failing visibly, so the arithmetic lives here where it can be tested
/// without the Rust FFI the renderer links.
enum RemoteTerminalDisplayRowMap {
    /// Cell range backing `row`, or nil when the row is out of range or the
    /// offsets are inconsistent with the cell count.
    static func range(row: Int, offsets: [UInt32], cellCount: Int) -> Range<Int>? {
        guard row >= 0, row + 1 < offsets.count else { return nil }
        let begin = Int(offsets[row])
        let end = Int(offsets[row + 1])
        guard begin <= end, end <= cellCount else { return nil }
        return begin ..< end
    }
}

enum RemoteTerminalWrapGeometry {
    /// Engine size to ingest into. Never narrower than the source width, since
    /// that is what reintroduces hard-wrap; the phone width only wins when the
    /// Mac did not announce a usable one.
    nonisolated static func engineSize(sourceCols: Int, displayCols: Int, displayRows: Int) -> (cols: Int, rows: Int) {
        let cols = max(1, max(sourceCols, displayCols))
        return (cols, max(1, displayRows))
    }

    /// Phone-width rows each source row is split into.
    static func chunksPerRow(sourceCols: Int, displayCols: Int) -> Int {
        guard sourceCols > 0, displayCols > 0 else { return 1 }
        return max(1, Int(ceil(Double(sourceCols) / Double(displayCols))))
    }

    /// Maps a phone-width display row back to the source row and the source
    /// column slice it paints. `nil` when the display row is out of range.
    ///
    /// The last chunk of a source row is narrower than `displayCols` whenever
    /// the source width is not a multiple of the phone width — the common case —
    /// so `colCount` is clamped to the columns that actually remain.
    static func sourceSlice(
        displayRow: Int,
        sourceCols: Int,
        sourceRows: Int,
        chunksPerRow: Int,
        displayCols: Int
    ) -> (sourceRow: Int, firstCol: Int, colCount: Int)? {
        guard chunksPerRow > 0, displayRow >= 0, displayCols > 0, sourceCols > 0 else { return nil }
        let sourceRow = displayRow / chunksPerRow
        guard sourceRow < sourceRows else { return nil }
        let firstCol = (displayRow % chunksPerRow) * displayCols
        guard firstCol < sourceCols else { return nil }
        let colCount = max(0, min(displayCols, sourceCols - firstCol))
        return (sourceRow, firstCol, colCount)
    }

    /// Total phone-width rows needed to show `sourceRows` source rows.
    static func displayRowCount(sourceRows: Int, chunksPerRow: Int) -> Int {
        max(0, sourceRows) * max(1, chunksPerRow)
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
