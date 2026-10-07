import XCTest
import Chau7Core
@testable import Chau7

@MainActor
final class RemoteGridSnapshotCoordinatorTests: XCTestCase {
    @MainActor
    private final class Fixture {
        var selected: UInt32? = 1
        var session = "first-pane"
        var connected = true
        var fullStream = true
        var eligible = true
        var requestedGenerations: [UInt64] = []
        var encodedScopes: [String] = []
        var completions: [@Sendable (RemoteGridSnapshotWorker.Result) -> Void] = []
        var delivered: [Data] = []
        var onCapture: (() -> Void)?
        var onDeliver: (() -> Void)?

        lazy var owner = RemoteGridSnapshotCoordinator(
            interval: .milliseconds(5),
            target: { [weak self] _ in
                guard let self else { return nil }
                return connected && fullStream && eligible ? session : nil
            },
            capture: { [weak self] _, generation in
                guard let self else { return nil }
                requestedGenerations.append(generation)
                onCapture?()
                return RemoteGridUpdate(
                    baseGeneration: generation, generation: generation + 1, fullRefresh: generation == 0,
                    rowIndices: [0], snapshot: RemoteTerminalGridSnapshot(
                        cols: 1, rows: 1, cursorCol: 0, cursorRow: 0, cursorVisible: true,
                        scrollbackRows: 0, displayOffset: 0, cells: Data(repeating: 0, count: 20), clusters: Data()
                    )
                )
            },
            context: { [weak self] _ in
                guard let self else { return .init(isConnected: false, streamsTerminal: false, selectedTab: nil, sessionID: nil) }
                return RemoteGridSnapshotCoordinator.Context(
                    isConnected: connected,
                    streamsTerminal: fullStream,
                    selectedTab: selected,
                    sessionID: session
                )
            },
            deliver: { [weak self] _, data in
                guard let self else { return }
                delivered.append(data)
                onDeliver?()
            },
            encodeForTesting: { [weak self] _, scope, completion in
                guard let self else { return }
                XCTAssertTrue(Thread.isMainThread)
                encodedScopes.append(scope)
                completions.append(completion)
            }
        )
        func finish(_ index: Int, payload: Data? = Data([1]), generation: UInt64 = 1) {
            completions[index](.init(payload: payload, generation: generation, retainedBytes: 20))
        }
    }

    func testBurstsCoalesceAndOnlyOneEncodingRuns() async {
        let f = Fixture()
        let captured = expectation(description: "coalesced capture")
        f.onCapture = { captured.fulfill() }
        for _ in 0 ..< 20 {
            f.owner.schedule(for: 1)
        }
        await fulfillment(of: [captured], timeout: 2)
        XCTAssertEqual(f.completions.count, 1)
        for _ in 0 ..< 20 {
            f.owner.request(for: 1, force: false)
        }
        XCTAssertEqual(f.completions.count, 1)
        let next = expectation(description: "latest pending capture")
        f.onCapture = { next.fulfill() }
        f.finish(0)
        await fulfillment(of: [next], timeout: 2)
        XCTAssertEqual(f.completions.count, 2)
        XCTAssertEqual(f.requestedGenerations, [0, 1])
        f.owner.invalidate()
    }

    func testForcedCheckpointSurvivesCoalescingWhileEncoding() async {
        let f = Fixture()
        f.owner.request(for: 1, force: false)
        f.owner.request(for: 1, force: true)
        f.owner.request(for: 1, force: false)
        let forced = expectation(description: "forced capture")
        f.onCapture = { forced.fulfill() }
        f.finish(0)
        await fulfillment(of: [forced], timeout: 2)
        XCTAssertEqual(f.requestedGenerations, [0, 0])
        f.owner.invalidate()
    }

    func testReconnectRejectsOldResultAndKeepsOneJobUntilRetirement() async {
        let f = Fixture()
        f.owner.request(for: 1)
        f.owner.invalidate()
        f.owner.request(for: 1)
        XCTAssertEqual(f.completions.count, 1)
        let replacement = expectation(description: "new epoch capture")
        f.onCapture = { replacement.fulfill() }
        f.finish(0)
        await fulfillment(of: [replacement], timeout: 2)
        XCTAssertTrue(f.delivered.isEmpty)
        XCTAssertEqual(f.requestedGenerations, [0, 0])
        XCTAssertNotEqual(f.encodedScopes[0], f.encodedScopes[1])
        f.owner.invalidate()
    }

    func testPaneReplacementRejectsOldResultAndUsesNewScope() async {
        let f = Fixture()
        f.owner.request(for: 1)
        f.session = "replacement-pane"
        f.owner.request(for: 1)
        let replacement = expectation(description: "replacement pane capture")
        f.onCapture = { replacement.fulfill() }
        f.finish(0)
        await fulfillment(of: [replacement], timeout: 2)
        XCTAssertTrue(f.delivered.isEmpty)
        XCTAssertEqual(f.requestedGenerations, [0, 0])
        XCTAssertNotEqual(f.encodedScopes[0], f.encodedScopes[1])
        f.owner.invalidate()
    }

    func testSelectionChangeKeepsLatestPendingTarget() async {
        let f = Fixture()
        f.owner.request(for: 1)
        f.owner.request(for: 2)
        f.owner.request(for: 3)
        f.selected = 3
        let latest = expectation(description: "latest selected capture")
        f.onCapture = { latest.fulfill() }
        f.finish(0)
        await fulfillment(of: [latest], timeout: 2)
        XCTAssertTrue(f.delivered.isEmpty)
        XCTAssertEqual(f.completions.count, 2)
        f.owner.invalidate()
    }

    func testUnchangedResultAdvancesGenerationAndCursorOnlyResultIsDelivered() async {
        let f = Fixture()
        f.owner.request(for: 1, force: false)
        f.owner.request(for: 1, force: false)
        let next = expectation(description: "after unchanged frame")
        f.onCapture = { next.fulfill() }
        f.finish(0, payload: nil, generation: 9)
        await fulfillment(of: [next], timeout: 2)
        XCTAssertTrue(f.delivered.isEmpty)
        XCTAssertEqual(f.requestedGenerations, [0, 9])
        let delivered = expectation(description: "cursor-only encoded bytes")
        f.onDeliver = { delivered.fulfill() }
        f.finish(1, payload: Data([2]), generation: 10)
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertEqual(f.delivered, [Data([2])])
        f.owner.invalidate()
    }

    func testLegacyOrDisconnectedTargetDoesNotCapture() {
        let f = Fixture()
        f.eligible = false
        f.owner.request(for: 1)
        f.eligible = true
        f.connected = false
        f.owner.request(for: 1)
        XCTAssertTrue(f.completions.isEmpty)
        XCTAssertTrue(f.requestedGenerations.isEmpty)
        f.owner.invalidate()
    }
}
