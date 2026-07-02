import XCTest
@testable import Chau7
@testable import Chau7Core

/// A6 contract: the schema-v4 ingest_seq column makes same-timestamp rows
/// order deterministically. The sequence is assigned by insert triggers from
/// one shared counter, so no insert statement carries the column.
final class TelemetryIngestSeqTests: XCTestCase {

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
}
