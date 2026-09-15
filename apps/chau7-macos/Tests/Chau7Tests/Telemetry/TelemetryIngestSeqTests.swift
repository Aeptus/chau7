import XCTest
@testable import Chau7
@testable import Chau7Core

/// A6 contract: the ingest_seq column makes same-timestamp rows
/// order deterministically. The sequence is assigned by insert triggers from
/// one shared counter, so no insert statement carries the column.
final class TelemetryIngestSeqTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // The shared telemetry store pins its SQLite connection to whichever
        // home was active at first init. An earlier test elsewhere in the suite
        // can isolate itself under a temp `CHAU7_HOME_ROOT` (later deleted),
        // leaving that connection pointing at a vanished database — so inserts
        // here would silently no-op and queries return nothing. Reopen at the
        // current (real) home to establish a live database before each test.
        TelemetryStore.shared.reopenForTesting()
    }

    private func makeRun(id: String, startedAt: Date, repoPath: String) -> TelemetryRun {
        TelemetryRun(
            id: id,
            provider: "codex",
            cwd: repoPath,
            repoPath: repoPath,
            startedAt: startedAt
        )
    }

    func testSameTimestampRunsOrderByInsertionOrder() {
        let repoPath = "/tmp/ingest-seq-\(UUID().uuidString)"
        // Identical started_at down to the encoded string.
        let sharedInstant = Date(timeIntervalSince1970: 1_751_000_000)

        let firstID = "run-\(UUID().uuidString)"
        let secondID = "run-\(UUID().uuidString)"
        TelemetryStore.shared.insertRun(makeRun(id: firstID, startedAt: sharedInstant, repoPath: repoPath))
        TelemetryStore.shared.insertRun(makeRun(id: secondID, startedAt: sharedInstant, repoPath: repoPath))

        var filter = TelemetryRunFilter()
        filter.repoPath = repoPath
        let listed = TelemetryStore.shared.listRuns(filter: filter)

        XCTAssertEqual(
            listed.map(\.id), [secondID, firstID],
            "started_at DESC ties must break by ingest_seq DESC (newest insert first) — got \(listed.map(\.id))"
        )
    }

    func testRepeatedListingsAreStable() {
        let repoPath = "/tmp/ingest-seq-stable-\(UUID().uuidString)"
        let sharedInstant = Date(timeIntervalSince1970: 1_751_100_000)
        for index in 0 ..< 5 {
            TelemetryStore.shared.insertRun(
                makeRun(id: "run-\(index)-\(UUID().uuidString)", startedAt: sharedInstant, repoPath: repoPath)
            )
        }
        var filter = TelemetryRunFilter()
        filter.repoPath = repoPath
        let first = TelemetryStore.shared.listRuns(filter: filter).map(\.id)
        for _ in 0 ..< 5 {
            XCTAssertEqual(TelemetryStore.shared.listRuns(filter: filter).map(\.id), first)
        }
    }

    func testSameTimestampLatencySamplesOrderByInsertionOrder() {
        let provider = "ingest-seq-\(UUID().uuidString.lowercased())"
        let sharedInstant = Date(timeIntervalSince1970: 1_751_200_000)
        // Deliberately oppose lexical ID order so this proves ingest_seq is
        // the tiebreaker rather than ProviderLatencySample.id.
        let firstID = "z-first-\(UUID().uuidString)"
        let secondID = "a-second-\(UUID().uuidString)"

        TelemetryStore.shared.insertLatencySample(
            ProviderLatencySample(
                id: firstID,
                provider: provider,
                metricKind: .apiRequest,
                latencyMs: 100,
                timestamp: sharedInstant,
                sourceKind: "ingest_seq_test"
            )
        )
        TelemetryStore.shared.insertLatencySample(
            ProviderLatencySample(
                id: secondID,
                provider: provider,
                metricKind: .apiRequest,
                latencyMs: 200,
                timestamp: sharedInstant,
                sourceKind: "ingest_seq_test"
            )
        )

        let listed = TelemetryStore.shared.latencySamples(
            after: sharedInstant.addingTimeInterval(-1),
            providerFilterKey: provider,
            metricKind: .apiRequest
        )

        XCTAssertEqual(
            listed.map(\.id), [firstID, secondID],
            "observed_at ASC ties must break by ingest_seq ASC — got \(listed.map(\.id))"
        )
    }
}
