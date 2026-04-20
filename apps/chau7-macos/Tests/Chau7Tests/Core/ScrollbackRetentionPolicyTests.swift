import XCTest
@testable import Chau7Core

final class ScrollbackRetentionPolicyTests: XCTestCase {
    func testVisiblePhasesKeepConfiguredScrollbackCapacity() {
        let configuredLines = 12000

        XCTAssertEqual(
            ScrollbackRetentionPolicy.ringCapacity(for: .active, configuredLines: configuredLines),
            configuredLines
        )
        XCTAssertEqual(
            ScrollbackRetentionPolicy.ringCapacity(for: .passiveVisible, configuredLines: configuredLines),
            configuredLines
        )
        XCTAssertEqual(
            ScrollbackRetentionPolicy.ringCapacity(for: .warm, configuredLines: configuredLines),
            configuredLines
        )
    }

    func testConfiguredScrollbackCapacityIsNormalizedForVisiblePhases() {
        XCTAssertEqual(
            ScrollbackRetentionPolicy.ringCapacity(for: .active, configuredLines: 10),
            ScrollbackRetentionPolicy.minimumConfiguredLines
        )
        XCTAssertEqual(
            ScrollbackRetentionPolicy.ringCapacity(for: .warm, configuredLines: 250_000),
            ScrollbackRetentionPolicy.maximumConfiguredLines
        )
    }

    func testHiddenPhaseUsesViewportFloorInsteadOfConfiguredScrollback() {
        XCTAssertEqual(
            ScrollbackRetentionPolicy.ringCapacity(
                for: .hidden,
                configuredLines: 12000,
                hiddenViewportFloor: 50
            ),
            50
        )
        XCTAssertEqual(
            ScrollbackRetentionPolicy.ringCapacity(
                for: .hidden,
                configuredLines: 12000,
                hiddenViewportFloor: -1
            ),
            0
        )
    }

    func testTransitionActionsOnlyCrossHiddenBoundary() {
        XCTAssertFalse(ScrollbackRetentionPolicy.shouldFlushToDisk(from: .active, to: .warm))
        XCTAssertTrue(ScrollbackRetentionPolicy.shouldFlushToDisk(from: .warm, to: .hidden))
        XCTAssertFalse(ScrollbackRetentionPolicy.shouldFlushToDisk(from: .hidden, to: .hidden))

        XCTAssertFalse(ScrollbackRetentionPolicy.shouldReloadFromDisk(from: .active, to: .warm))
        XCTAssertTrue(ScrollbackRetentionPolicy.shouldReloadFromDisk(from: .hidden, to: .active))
        XCTAssertFalse(ScrollbackRetentionPolicy.shouldReloadFromDisk(from: .hidden, to: .hidden))
    }
}
