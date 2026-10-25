import Foundation

/// The single merge authority for the iOS client's pending approvals and
/// interactive prompts.
///
/// Two channels feed this state with different semantics — WS frames deliver
/// incremental upserts/list-replaces, and the REST `/pending` snapshot
/// replaces wholesale — and they race: the snapshot fetch fires on
/// scene-active / push-wake / session-ready, routinely concurrent with live
/// WS delivery. Before this type existed the snapshot was applied blindly,
/// so a stale snapshot could clobber an approval that had just arrived over
/// the WS, or resurrect one the user had just resolved.
///
/// Invariants enforced here:
/// 1. A snapshot never removes an approval that was WS-upserted at/after the
///    moment the fetch began, or whose response is in flight (busy).
/// 2. A snapshot never re-adds an approval the user resolved locally within
///    the resolution retention window.
/// 3. A snapshot's prompt list is ignored entirely when a WS prompt list
///    arrived after the fetch began (the WS list is strictly newer).
///
/// Pure value type: every mutation takes `now` explicitly, so any
/// interleaving of deltas and snapshots is replayable in tests.
public struct PendingStateReconciler: Sendable {

    /// How long a local resolution suppresses snapshot re-adds. Generous:
    /// the agent clears resolved approvals from its own pending store on the
    /// response frame, so a snapshot older than this window shouldn't exist.
    public static let resolutionRetention: TimeInterval = 120

    /// The outcome of a merge: the authoritative approval list plus the
    /// deltas the UI layer needs for notification scheduling/cancellation.
    public struct ApprovalChanges: Equatable, Sendable {
        public let approvals: [ApprovalRequestPayload]
        public let added: [ApprovalRequestPayload]
        public let removedIDs: [String]

        public init(approvals: [ApprovalRequestPayload], added: [ApprovalRequestPayload], removedIDs: [String]) {
            self.approvals = approvals
            self.added = added
            self.removedIDs = removedIDs
        }
    }

    public struct PromptChanges: Equatable, Sendable {
        public let prompts: [RemoteInteractivePrompt]
        public let added: [RemoteInteractivePrompt]
        public let removedIDs: [String]

        public init(prompts: [RemoteInteractivePrompt], added: [RemoteInteractivePrompt], removedIDs: [String]) {
            self.prompts = prompts
            self.added = added
            self.removedIDs = removedIDs
        }
    }

    private(set) var approvals: [ApprovalRequestPayload] = []
    private(set) var prompts: [RemoteInteractivePrompt] = []

    /// requestID → when the user resolved it locally (journal, invariant 2).
    private var locallyResolvedApprovals: [String: Date] = [:]
    /// requestID → when a WS upsert delivered it (journal, invariant 1).
    private var wsUpsertTimes: [String: Date] = [:]
    /// When the most recent snapshot fetch began (nil = none in flight).
    private var snapshotFetchStartedAt: Date?
    /// Last applied snapshot arbitration coordinates (phase B). Nil until a
    /// versioned snapshot has been seen.
    private var lastSnapshotEpoch: String?
    private var lastSnapshotVersion: UInt64?
    /// When the last WS prompt list arrived (invariant 3).
    private var lastWSPromptListAt: Date?

    public init() {}

    // MARK: - WS deltas

    /// Incremental approval upsert from a WS `approvalRequest` frame.
    public mutating func applyWSApprovalUpsert(_ payload: ApprovalRequestPayload, now: Date) -> ApprovalChanges {
        wsUpsertTimes[payload.requestID] = now
        locallyResolvedApprovals.removeValue(forKey: payload.requestID)

        if let index = approvals.firstIndex(where: { $0.requestID == payload.requestID }) {
            approvals[index] = payload
            return ApprovalChanges(approvals: approvals, added: [], removedIDs: [])
        }
        approvals.append(payload)
        return ApprovalChanges(approvals: approvals, added: [payload], removedIDs: [])
    }

    /// Full prompt-list replace from a WS `interactivePromptList` frame.
    public mutating func applyWSPromptList(_ nextPrompts: [RemoteInteractivePrompt], now: Date) -> PromptChanges {
        lastWSPromptListAt = now
        return replacePrompts(with: nextPrompts)
    }

    // MARK: - Local resolutions

    /// The user answered (or the response completed) an approval on-device.
    public mutating func applyLocalApprovalResolution(requestID: String, now: Date) -> ApprovalChanges {
        locallyResolvedApprovals[requestID] = now
        wsUpsertTimes.removeValue(forKey: requestID)
        guard let index = approvals.firstIndex(where: { $0.requestID == requestID }) else {
            return ApprovalChanges(approvals: approvals, added: [], removedIDs: [])
        }
        approvals.remove(at: index)
        return ApprovalChanges(approvals: approvals, added: [], removedIDs: [requestID])
    }

    /// The user answered/dismissed a prompt on-device.
    public mutating func applyLocalPromptCompletion(promptID: String) -> PromptChanges {
        guard let index = prompts.firstIndex(where: { $0.id == promptID }) else {
            return PromptChanges(prompts: prompts, added: [], removedIDs: [])
        }
        prompts.remove(at: index)
        return PromptChanges(prompts: prompts, added: [], removedIDs: [promptID])
    }

    // MARK: - REST snapshot

    /// Mark the moment a `/pending` fetch is issued. Everything that arrives
    /// over the WS at/after this instant outranks the snapshot's contents.
    public mutating func beginSnapshotFetch(now: Date) {
        snapshotFetchStartedAt = now
        pruneResolutionJournal(now: now)
    }

    /// Phase-B arbitration: should a snapshot with these coordinates be
    /// applied at all? Unversioned snapshots (older agents) are always
    /// eligible — the delta-journal invariants remain their protection.
    /// Applying updates the arbitration state.
    public mutating func admitSnapshot(epoch: String?, version: UInt64?) -> Bool {
        guard let epoch, let version else { return true }
        if epoch != lastSnapshotEpoch {
            // New agent session generation: previous ordering is void.
            lastSnapshotEpoch = epoch
            lastSnapshotVersion = version
            return true
        }
        if let lastVersion = lastSnapshotVersion, version <= lastVersion {
            return false
        }
        lastSnapshotVersion = version
        return true
    }

    /// Merge a `/pending` snapshot's approvals (invariants 1 + 2).
    /// `busyRequestIDs` are approvals whose responses are queued/sending on
    /// this device — the snapshot may not remove them.
    public mutating func applySnapshotApprovals(
        _ payloads: [ApprovalRequestPayload],
        busyRequestIDs: Set<String>,
        now: Date
    ) -> ApprovalChanges {
        let fetchStart = snapshotFetchStartedAt ?? now
        pruneResolutionJournal(now: now)

        // Invariant 2: drop snapshot entries the user already resolved.
        let snapshotEntries = payloads.filter { locallyResolvedApprovals[$0.requestID] == nil }
        var merged = snapshotEntries

        // Invariant 1: keep approvals the snapshot doesn't know about when
        // they were WS-upserted after the fetch began, or are busy.
        let snapshotIDs = Set(snapshotEntries.map(\.requestID))
        for approval in approvals where !snapshotIDs.contains(approval.requestID) {
            let upsertedAfterFetch = wsUpsertTimes[approval.requestID].map { $0 >= fetchStart } ?? false
            if upsertedAfterFetch || busyRequestIDs.contains(approval.requestID) {
                merged.append(approval)
            }
        }

        let previousIDs = Set(approvals.map(\.requestID))
        let mergedIDs = Set(merged.map(\.requestID))
        let added = merged.filter { !previousIDs.contains($0.requestID) }
        let removedIDs = Array(previousIDs.subtracting(mergedIDs))

        approvals = merged
        snapshotFetchStartedAt = nil
        return ApprovalChanges(approvals: merged, added: added, removedIDs: removedIDs)
    }

    /// Merge a `/pending` snapshot's prompt list (invariant 3). Returns nil
    /// when the snapshot is outranked by a newer WS prompt list — the caller
    /// must not touch prompt state in that case.
    public mutating func applySnapshotPrompts(
        _ nextPrompts: [RemoteInteractivePrompt],
        now: Date
    ) -> PromptChanges? {
        let fetchStart = snapshotFetchStartedAt ?? now
        if let lastWS = lastWSPromptListAt, lastWS >= fetchStart {
            return nil
        }
        return replacePrompts(with: nextPrompts)
    }

    /// Clear everything (unpair / explicit reset).
    public mutating func reset() {
        approvals = []
        prompts = []
        locallyResolvedApprovals = [:]
        wsUpsertTimes = [:]
        snapshotFetchStartedAt = nil
        lastWSPromptListAt = nil
        lastSnapshotEpoch = nil
        lastSnapshotVersion = nil
    }

    // MARK: - Private

    private mutating func replacePrompts(with nextPrompts: [RemoteInteractivePrompt]) -> PromptChanges {
        let previousIDs = Set(prompts.map(\.id))
        let nextIDs = Set(nextPrompts.map(\.id))
        let added = nextPrompts.filter { !previousIDs.contains($0.id) }
        let removedIDs = Array(previousIDs.subtracting(nextIDs))
        prompts = nextPrompts
        return PromptChanges(prompts: nextPrompts, added: added, removedIDs: removedIDs)
    }

    private mutating func pruneResolutionJournal(now: Date) {
        locallyResolvedApprovals = locallyResolvedApprovals.filter {
            now.timeIntervalSince($0.value) < Self.resolutionRetention
        }
    }
}
