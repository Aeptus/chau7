import XCTest
@testable import Chau7Core

final class RestoreSourceArbiterTests: XCTestCase {
    func testMatchingTokensPreferBundle() {
        XCTAssertTrue(RestoreSourceArbiter.bundleIsCurrent(bundleToken: "t1", indexToken: "t1"))
    }

    func testMismatchedTokensPreferIndex() {
        XCTAssertFalse(RestoreSourceArbiter.bundleIsCurrent(bundleToken: "t1", indexToken: "t2"))
    }

    func testTokenlessBundleAgainstTokenedIndexPrefersIndex() {
        // The bundle predates the latest save cycle (or predates tokens
        // entirely while the index has saved since) — it missed a save.
        XCTAssertFalse(RestoreSourceArbiter.bundleIsCurrent(bundleToken: nil, indexToken: "t1"))
    }

    func testTokenlessIndexKeepsBundleFirstBehavior() {
        // No index token: pre-token persisted state or no index at all.
        XCTAssertTrue(RestoreSourceArbiter.bundleIsCurrent(bundleToken: "t1", indexToken: nil))
        XCTAssertTrue(RestoreSourceArbiter.bundleIsCurrent(bundleToken: nil, indexToken: nil))
    }
}
