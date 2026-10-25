import XCTest
@testable import Chau7Core

/// Pins the NF-1 fix: WS deltas, REST snapshots, and local resolutions all
/// merge through one reconciler whose invariants make stale snapshots unable
/// to clobber newer state.
final class PendingStateReconcilerTests: XCTestCase {

    private func approval(_ id: String, command: String = "cmd") -> ApprovalRequestPayload {
        ApprovalRequestPayload(
            requestID: id,
            command: command,
            flaggedCommand: command,
            timestamp: "2026-07-01T12:00:00Z",
            sessionID: "sess-\(id)"
        )
    }

    private func prompt(_ id: String) -> RemoteInteractivePrompt {
        RemoteInteractivePrompt(
            id: id, tabID: 1, tabTitle: "tab", toolName: "Claude Code",
            prompt: "Continue?", options: [], detectedAt: Date(timeIntervalSince1970: 0)
        )
    }

    // MARK: - NF-1: stale snapshot vs fresh WS upsert

    func testStaleSnapshotCannotRemoveApprovalUpsertedAfterFetchBegan() {
        var reconciler = PendingStateReconciler()
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        // Fetch begins (snapshot will reflect the server state at ~t0)…
        reconciler.beginSnapshotFetch(now: t0)
        // …then a fresh approval arrives over the WS.
        _ = reconciler.applyWSApprovalUpsert(approval("fresh"), now: t0.addingTimeInterval(0.5))
        // The (stale) snapshot lands without the fresh approval.
        let changes = reconciler.applySnapshotApprovals([approval("old")], busyRequestIDs: [], now: t0.addingTimeInterval(1))

        XCTAssertEqual(Set(changes.approvals.map(\.requestID)), ["old", "fresh"], "fresh WS approval must survive the stale snapshot")
        XCTAssertTrue(changes.removedIDs.isEmpty)
    }

    func testSnapshotRemovesApprovalTheMacResolvedElsewhere() {
        var reconciler = PendingStateReconciler()
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        // Approval arrived long before the fetch began — the snapshot's
        // omission of it is authoritative (resolved on the Mac or another
        // device).
        _ = reconciler.applyWSApprovalUpsert(approval("resolved-elsewhere"), now: t0)
        reconciler.beginSnapshotFetch(now: t0.addingTimeInterval(10))
        let changes = reconciler.applySnapshotApprovals([], busyRequestIDs: [], now: t0.addingTimeInterval(11))

        XCTAssertTrue(changes.approvals.isEmpty)
        XCTAssertEqual(changes.removedIDs, ["resolved-elsewhere"])
    }

    func testSnapshotCannotRemoveBusyApproval() {
        var reconciler = PendingStateReconciler()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        _ = reconciler.applyWSApprovalUpsert(approval("busy"), now: t0)
        reconciler.beginSnapshotFetch(now: t0.addingTimeInterval(10))
        let changes = reconciler.applySnapshotApprovals([], busyRequestIDs: ["busy"], now: t0.addingTimeInterval(11))
        XCTAssertEqual(changes.approvals.map(\.requestID), ["busy"], "an in-flight response pins its approval")
    }

    func testSnapshotCannotResurrectLocallyResolvedApproval() {
        var reconciler = PendingStateReconciler()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        _ = reconciler.applyWSApprovalUpsert(approval("answered"), now: t0)
        _ = reconciler.applyLocalApprovalResolution(requestID: "answered", now: t0.addingTimeInterval(1))

        reconciler.beginSnapshotFetch(now: t0.addingTimeInterval(2))
        // Stale snapshot still lists the answered approval.
        let changes = reconciler.applySnapshotApprovals([approval("answered")], busyRequestIDs: [], now: t0.addingTimeInterval(3))
        XCTAssertTrue(changes.approvals.isEmpty, "resolved approval must not resurrect from a stale snapshot")
        XCTAssertTrue(changes.added.isEmpty)
    }

    func testResolutionRetentionExpires() {
        var reconciler = PendingStateReconciler()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        _ = reconciler.applyWSApprovalUpsert(approval("r1"), now: t0)
        _ = reconciler.applyLocalApprovalResolution(requestID: "r1", now: t0)

        // Long after the retention window, a snapshot listing it is trusted
        // again (a genuinely re-issued request with the same ID).
        let late = t0.addingTimeInterval(PendingStateReconciler.resolutionRetention + 1)
        reconciler.beginSnapshotFetch(now: late)
        let changes = reconciler.applySnapshotApprovals([approval("r1")], busyRequestIDs: [], now: late)
        XCTAssertEqual(changes.approvals.map(\.requestID), ["r1"])
    }

    // MARK: - WS upsert semantics

    func testWSUpsertUpdatesInPlaceAndReportsAddsOnce() {
        var reconciler = PendingStateReconciler()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let first = reconciler.applyWSApprovalUpsert(approval("a", command: "v1"), now: t0)
        XCTAssertEqual(first.added.map(\.requestID), ["a"])
        let second = reconciler.applyWSApprovalUpsert(approval("a", command: "v2"), now: t0.addingTimeInterval(1))
        XCTAssertTrue(second.added.isEmpty, "an update to an existing approval is not a new add")
        XCTAssertEqual(second.approvals.first?.command, "v2")
    }

    func testWSUpsertClearsLocalResolutionJournal() {
        var reconciler = PendingStateReconciler()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        _ = reconciler.applyWSApprovalUpsert(approval("x"), now: t0)
        _ = reconciler.applyLocalApprovalResolution(requestID: "x", now: t0.addingTimeInterval(1))
        // The Mac re-issues the same request id — a genuinely new ask.
        let changes = reconciler.applyWSApprovalUpsert(approval("x"), now: t0.addingTimeInterval(2))
        XCTAssertEqual(changes.approvals.map(\.requestID), ["x"])
        XCTAssertEqual(changes.added.map(\.requestID), ["x"])
    }

    // MARK: - Prompt arbitration (invariant 3)

    func testStaleSnapshotPromptsIgnoredWhenWSListIsNewer() {
        var reconciler = PendingStateReconciler()
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        reconciler.beginSnapshotFetch(now: t0)
        _ = reconciler.applyWSPromptList([prompt("p-new")], now: t0.addingTimeInterval(0.5))

        let snapshotResult = reconciler.applySnapshotPrompts([prompt("p-old")], now: t0.addingTimeInterval(1))
        XCTAssertNil(snapshotResult, "snapshot prompts must be ignored when a newer WS list exists")
        XCTAssertEqual(reconciler.prompts.map(\.id), ["p-new"])
    }

    func testSnapshotPromptsApplyWhenNoNewerWSList() {
        var reconciler = PendingStateReconciler()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        _ = reconciler.applyWSPromptList([prompt("p1")], now: t0)
        reconciler.beginSnapshotFetch(now: t0.addingTimeInterval(5))
        let changes = reconciler.applySnapshotPrompts([prompt("p2")], now: t0.addingTimeInterval(6))
        XCTAssertEqual(changes?.prompts.map(\.id), ["p2"])
        XCTAssertEqual(changes?.removedIDs, ["p1"])
        XCTAssertEqual(changes?.added.map(\.id), ["p2"])
    }

    // MARK: - Convergence property

    /// Any interleaving of the same operations converges to the same final
    /// state: the WS-upserted approval survives, the resolved one stays gone.
    func testInterleavingsConverge() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let snapshotBody = [approval("old"), approval("answered")]

        // Interleaving A: fetch → ws upsert → local resolve → snapshot
        var a = PendingStateReconciler()
        _ = a.applyWSApprovalUpsert(approval("answered"), now: t0.addingTimeInterval(-5))
        a.beginSnapshotFetch(now: t0)
        _ = a.applyWSApprovalUpsert(approval("fresh"), now: t0.addingTimeInterval(0.2))
        _ = a.applyLocalApprovalResolution(requestID: "answered", now: t0.addingTimeInterval(0.4))
        let finalA = a.applySnapshotApprovals(snapshotBody, busyRequestIDs: [], now: t0.addingTimeInterval(1))

        // Interleaving B: ws upsert → local resolve → fetch → snapshot
        var b = PendingStateReconciler()
        _ = b.applyWSApprovalUpsert(approval("answered"), now: t0.addingTimeInterval(-5))
        _ = b.applyWSApprovalUpsert(approval("fresh"), now: t0.addingTimeInterval(0.2))
        _ = b.applyLocalApprovalResolution(requestID: "answered", now: t0.addingTimeInterval(0.4))
        b.beginSnapshotFetch(now: t0.addingTimeInterval(0.6))
        let finalB = b.applySnapshotApprovals(snapshotBody, busyRequestIDs: ["fresh"], now: t0.addingTimeInterval(1))

        XCTAssertEqual(Set(finalA.approvals.map(\.requestID)), ["old", "fresh"])
        XCTAssertEqual(Set(finalB.approvals.map(\.requestID)), ["old", "fresh"])
    }
}

/// Phase-B snapshot arbitration: versioned snapshots are ordered by
/// (session_epoch, state_version); unversioned ones stay journal-protected.
final class PendingStateArbitrationTests: XCTestCase {

    func testStaleVersionWithinEpochIsRejected() {
        var reconciler = PendingStateReconciler()
        XCTAssertTrue(reconciler.admitSnapshot(epoch: "e1", version: 5))
        XCTAssertFalse(reconciler.admitSnapshot(epoch: "e1", version: 5), "same version is stale")
        XCTAssertFalse(reconciler.admitSnapshot(epoch: "e1", version: 3), "lower version is stale")
        XCTAssertTrue(reconciler.admitSnapshot(epoch: "e1", version: 6))
    }

    func testNewEpochResetsArbitration() {
        var reconciler = PendingStateReconciler()
        XCTAssertTrue(reconciler.admitSnapshot(epoch: "e1", version: 100))
        // Agent restarted: fresh epoch, counter restarts low — still admitted.
        XCTAssertTrue(reconciler.admitSnapshot(epoch: "e2", version: 1))
        XCTAssertFalse(reconciler.admitSnapshot(epoch: "e2", version: 1))
    }

    func testUnversionedSnapshotsAlwaysAdmitted() {
        var reconciler = PendingStateReconciler()
        XCTAssertTrue(reconciler.admitSnapshot(epoch: nil, version: nil))
        _ = reconciler.admitSnapshot(epoch: "e1", version: 9)
        XCTAssertTrue(reconciler.admitSnapshot(epoch: nil, version: nil), "older agents stay journal-protected, never blocked")
    }
}

/// Pins the NF-2 fix: agent restarts no longer deadlock the replay guard.
final class RemoteReplayGuardTests: XCTestCase {

    func testMonotonicSequenceAcceptsAndBumps() {
        var guardState = RemoteReplayGuard()
        XCTAssertEqual(guardState.evaluateEncryptedFrame(seq: 1), .accept)
        XCTAssertEqual(guardState.evaluateEncryptedFrame(seq: 2), .accept)
        XCTAssertEqual(guardState.maxReceivedSeq, 2)
    }

    func testReplayedFrameDrops() {
        var guardState = RemoteReplayGuard()
        _ = guardState.evaluateEncryptedFrame(seq: 5)
        guard case .drop = guardState.evaluateEncryptedFrame(seq: 5) else {
            return XCTFail("equal seq must drop")
        }
        guard case .drop = guardState.evaluateEncryptedFrame(seq: 3) else {
            return XCTFail("lower seq must drop")
        }
    }

    func testHelloNonceChangeWithActiveSessionOrdersReset() {
        var guardState = RemoteReplayGuard()
        let nonceA = Data("nonce-a".utf8)
        let nonceB = Data("nonce-b".utf8)

        XCTAssertEqual(guardState.evaluateHello(macNonce: nonceA, hasCryptoSession: false), .accept)
        _ = guardState.evaluateEncryptedFrame(seq: 100)

        // Agent restarts and re-handshakes with a fresh nonce.
        guard case .resetSession = guardState.evaluateHello(macNonce: nonceB, hasCryptoSession: true) else {
            return XCTFail("nonce change with active session must order a reset")
        }
        // Seq space is reset: the agent's fresh counter is accepted again.
        XCTAssertEqual(guardState.evaluateEncryptedFrame(seq: 1), .accept)
    }

    func testSameNonceHelloIsAccepted() {
        var guardState = RemoteReplayGuard()
        let nonce = Data("nonce".utf8)
        XCTAssertEqual(guardState.evaluateHello(macNonce: nonce, hasCryptoSession: false), .accept)
        XCTAssertEqual(guardState.evaluateHello(macNonce: nonce, hasCryptoSession: true), .accept)
    }

    func testConsecutiveDecryptFailuresOrderReset() {
        var guardState = RemoteReplayGuard()
        _ = guardState.evaluateEncryptedFrame(seq: 42)

        for attempt in 1 ..< RemoteReplayGuard.decryptFailureThreshold {
            guard case .drop = guardState.noteDecryptFailure() else {
                return XCTFail("failure \(attempt) below threshold must drop, not reset")
            }
        }
        guard case .resetSession = guardState.noteDecryptFailure() else {
            return XCTFail("threshold reached — must order a reset")
        }
        XCTAssertEqual(guardState.maxReceivedSeq, 0)
    }

    func testDecryptSuccessResetsFailureStreak() {
        var guardState = RemoteReplayGuard()
        for _ in 1 ..< RemoteReplayGuard.decryptFailureThreshold {
            _ = guardState.noteDecryptFailure()
        }
        guardState.noteDecryptSuccess()
        guard case .drop = guardState.noteDecryptFailure() else {
            return XCTFail("streak was reset — a single failure must only drop")
        }
    }
}
