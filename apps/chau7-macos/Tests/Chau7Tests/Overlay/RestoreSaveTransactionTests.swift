import XCTest
@testable import Chau7Core

final class RestoreSaveTransactionTests: XCTestCase {
    func testPublishesIndexOnlyAfterBundleAndTokenLast() {
        var events: [String] = []

        let result = RestoreSaveTransaction.commit(
            indexPayloadIsReady: true,
            persistBundle: { events.append("bundle"); return true },
            publishIndexPayload: { events.append("index-payload") },
            publishIndexToken: { events.append("index-token") }
        )

        XCTAssertEqual(result, .bundleAndIndex)
        XCTAssertEqual(events, ["bundle", "index-payload", "index-token"])
    }

    func testBundleFailureDoesNotPublishIndex() {
        var events: [String] = []

        let result = RestoreSaveTransaction.commit(
            indexPayloadIsReady: true,
            persistBundle: { events.append("bundle"); return false },
            publishIndexPayload: { events.append("index-payload") },
            publishIndexToken: { events.append("index-token") }
        )

        XCTAssertEqual(result, .bundleNotPersisted)
        XCTAssertEqual(events, ["bundle"])
    }

    func testEncodingFailureLeavesCommittedBundleAheadOfIndex() {
        var events: [String] = []

        let result = RestoreSaveTransaction.commit(
            indexPayloadIsReady: false,
            persistBundle: { events.append("bundle"); return true },
            publishIndexPayload: { events.append("index-payload") },
            publishIndexToken: { events.append("index-token") }
        )

        XCTAssertEqual(result, .bundleOnly)
        XCTAssertEqual(events, ["bundle"])
    }
}
