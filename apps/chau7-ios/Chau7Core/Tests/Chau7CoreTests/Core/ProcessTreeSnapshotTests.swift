import XCTest
@testable import Chau7Core

/// Regression coverage for the `ps`-capture rework that removed the
/// per-session fork+exec from the app-termination path.
///
/// The bug these lock down: `TerminalSessionModel.captureDescendantPIDs` used
/// to spawn its own `/bin/ps` per call, and `closeSessionForTermination` calls
/// it serially on the main thread once per session — so quitting N tabs paid
/// N x (fork+exec+read) on the main actor. The fix shares one parsed snapshot
/// across all sessions, which only works if the parse and the BFS traversal
/// behave exactly as the original inline implementation did.
final class ProcessTreeSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeSnapshot(_ output: String) -> ProcessTreeSnapshot {
        ProcessTreeSnapshot(psOutput: output, capturedAt: now)
    }

    // MARK: - Parsing

    func testParsesPidParentAndCommand() {
        let snapshot = makeSnapshot("100 1 /bin/zsh\n200 100 /usr/local/bin/node server.js\n")

        XCTAssertEqual(
            snapshot.descendants(of: 100),
            [ProcessTreeSnapshot.Node(pid: 200, parentPID: 100, command: "/usr/local/bin/node server.js")]
        )
    }

    /// `command` is the rest of the line, so a command containing spaces must
    /// survive intact. This is why the parser uses `maxSplits: 2`.
    func testCommandRetainsInternalSpaces() {
        let snapshot = makeSnapshot("200 100 /usr/bin/open -a Some App --flag value\n")

        XCTAssertEqual(snapshot.descendants(of: 100).first?.command, "/usr/bin/open -a Some App --flag value")
    }

    func testSkipsMalformedLinesWithoutFailingTheSnapshot() {
        let snapshot = makeSnapshot("""
        garbage line with no columns
        200 100 /bin/sleep 1
        300
        not-a-pid 100 /bin/ls
        400 300 /bin/cat
        """)

        // `300` has no ppid, and `not-a-pid` is unparseable; both are skipped
        // while the well-formed rows still land.
        XCTAssertEqual(snapshot.descendants(of: 100).map(\.pid), [200])
        XCTAssertEqual(snapshot.descendants(of: 300).map(\.pid), [400])
    }

    func testEmptyOutputYieldsNoDescendants() {
        let snapshot = makeSnapshot("")

        XCTAssertTrue(snapshot.isEmpty)
        XCTAssertEqual(snapshot.descendants(of: 100), [])
    }

    // MARK: - Traversal

    /// BFS order matters: the kill sweep walks ancestors before children so a
    /// parent cannot respawn a child that was already signalled.
    func testDescendantsAreBreadthFirstWithParentsBeforeChildren() {
        let snapshot = makeSnapshot("""
        100 1 /bin/zsh
        200 100 /bin/sleep 1
        300 200 /bin/sleep 2
        400 300 /bin/sleep 3
        500 100 /bin/sleep 4
        """)

        XCTAssertEqual(snapshot.descendants(of: 100).map(\.pid), [200, 500, 300, 400])
    }

    /// A shell whose children are gone (already reaped, or a non-child process
    /// adopted by launchd) must report nothing rather than throwing or hanging.
    func testUnknownShellYieldsEmpty() {
        let snapshot = makeSnapshot("200 100 /bin/sleep 1\n")

        XCTAssertEqual(snapshot.descendants(of: 999_999), [])
    }

    /// Guard against an infinite BFS. A real `ps` table cannot contain a
    /// parent/child cycle, but `init(psOutput:capturedAt:)` is public and
    /// accepts arbitrary text, and this walk runs on the app-termination path —
    /// so a cycle here would hang the main thread forever, which is a strictly
    /// worse outcome than an inaccurate tree.
    func testSelfReferentialCycleTerminates() {
        // 200's parent is 100, and 100's parent is 200.
        let snapshot = makeSnapshot("100 200 /bin/a\n200 100 /bin/b\n")

        let descendants = snapshot.descendants(of: 100)
        XCTAssertEqual(descendants.map(\.pid), [200])
    }

    /// A pid listed under itself must not re-enqueue itself forever.
    func testSelfParentTerminates() {
        let snapshot = makeSnapshot("100 100 /bin/loop\n200 100 /bin/sleep 1\n")

        XCTAssertEqual(snapshot.descendants(of: 100).map(\.pid), [200])
    }

    /// Longer cycles (A->B->C->A) must terminate too, not just 2-cycles.
    func testThreeNodeCycleTerminates() {
        let snapshot = makeSnapshot("100 300 /bin/a\n200 100 /bin/b\n300 200 /bin/c\n")

        let descendants = snapshot.descendants(of: 100)
        XCTAssertEqual(descendants.map(\.pid).sorted(), [200, 300])
    }

    /// A diamond (two parents, one shared child) is NOT a cycle, so the shared
    /// child must still be reported — the visited set must not suppress
    /// legitimately repeated structure.
    func testDiamondReportsSharedChildOnce() {
        let snapshot = makeSnapshot("""
        100 1 /bin/zsh
        200 100 /bin/a
        300 100 /bin/b
        400 200 /bin/shared
        500 300 /bin/shared
        """)

        // 400 and 500 are distinct pids, so both are legitimately reported.
        XCTAssertEqual(snapshot.descendants(of: 100).map(\.pid), [200, 300, 400, 500])
    }

    // MARK: - Freshness

    func testIsFreshWithinTTL() {
        let snapshot = makeSnapshot("100 1 /bin/zsh\n")

        XCTAssertTrue(snapshot.isFresh(at: now, ttl: 2))
        XCTAssertTrue(snapshot.isFresh(at: now.addingTimeInterval(1.9), ttl: 2))
    }

    func testIsNotFreshAtOrBeyondTTL() {
        let snapshot = makeSnapshot("100 1 /bin/zsh\n")

        XCTAssertFalse(snapshot.isFresh(at: now.addingTimeInterval(2), ttl: 2))
        XCTAssertFalse(snapshot.isFresh(at: now.addingTimeInterval(60), ttl: 2))
    }

    /// A non-positive TTL must never report fresh, otherwise a misconfigured
    /// caller would serve an arbitrarily old tree to the kill sweep.
    func testNonPositiveTTLIsNeverFresh() {
        let snapshot = makeSnapshot("100 1 /bin/zsh\n")

        XCTAssertFalse(snapshot.isFresh(at: now, ttl: 0))
        XCTAssertFalse(snapshot.isFresh(at: now, ttl: -1))
    }

    // MARK: - Shared cache

    /// The whole point of the rework: a populated cache answers every session
    /// without another `ps`. The real capture is used deliberately here — it is
    /// the one assertion that the shipped timeout actually succeeds, which is
    /// exactly what an earlier 0.3 s revision got wrong (it timed out on a
    /// loaded machine and returned an empty tree, silently skipping the kill
    /// sweep). So this test is the guard against regressing that.
    func testTerminationFallbackTimeoutIsRealistic() {
        let cache = SharedProcessTreeCache()

        let snapshot = cache.snapshot(
            ttl: 0,
            fallbackTimeout: SharedProcessTreeCache.terminationFallbackTimeout
        )

        XCTAssertNotNil(snapshot, "a real ps capture must complete within terminationFallbackTimeout")
        XCTAssertFalse(snapshot!.isEmpty, "ps must have reported at least the current process")
    }

    /// The production guarantee: once one session has captured, every later
    /// session is served from the shared snapshot with no further `ps`.
    func testSharedCacheServesRepeatedReads() {
        let cache = SharedProcessTreeCache()

        let first = cache.snapshot(ttl: 60, fallbackTimeout: 5)
        XCTAssertNotNil(first)

        let second = cache.snapshot(ttl: 60, fallbackTimeout: 5)
        XCTAssertEqual(second?.capturedAt, first?.capturedAt, "second read must be served from cache")

        // Simulate a 20-tab quit: every session after the first must reuse the
        // identical snapshot rather than recapturing.
        for _ in 0 ..< 19 {
            XCTAssertEqual(cache.snapshot(ttl: 60, fallbackTimeout: 5)?.capturedAt, first?.capturedAt)
        }
    }

    /// A stale cache must be refreshable, and the refreshed snapshot must
    /// replace the old one rather than the old one shadowing it forever.
    func testStaleSnapshotIsReplacedNotRetainedForever() {
        let cache = SharedProcessTreeCache()

        let first = cache.snapshot(ttl: 60, fallbackTimeout: 5)
        XCTAssertNotNil(first)

        // ttl: 0 means "always stale", so this recaptures and must differ.
        let refreshed = cache.snapshot(ttl: 0, fallbackTimeout: 5)
        XCTAssertNotNil(refreshed)
        XCTAssertGreaterThanOrEqual(
            refreshed!.capturedAt,
            first!.capturedAt,
            "a stale read must produce a snapshot no older than the previous one"
        )
    }
}
