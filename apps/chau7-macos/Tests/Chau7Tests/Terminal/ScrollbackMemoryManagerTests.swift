import XCTest
@testable import Chau7
@testable import Chau7Core

final class ScrollbackMemoryManagerTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScrollbackMemoryManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
    }

    func testHiddenDemotionDoesNotShrinkRingWhenCacheWriteFails() {
        let tabID = UUID()
        let rust = MockScrollbackRustFFI(capturedText: "line 1\nline 2\n")
        let manager = ScrollbackMemoryManager(
            cacheDirectory: tempDirectory,
            cacheWriter: { _, _ in throw TestError.writeFailed }
        )

        manager.handlePhaseTransition(
            viewId: "test",
            tabID: tabID,
            rustFFI: rust,
            from: .warm,
            to: .hidden
        )
        manager.drainPendingOperationsForTesting(tabID: tabID)

        XCTAssertTrue(
            rust.scrollbackSizes.isEmpty,
            "Failed hidden flush must leave the existing Rust ring capacity untouched."
        )
    }

    func testHiddenDemotionShrinksAfterVerifiedCacheWriteAndReloadsPayload() {
        let tabID = UUID()
        let text = "alpha\nbeta\ngamma\n"
        let rust = MockScrollbackRustFFI(capturedText: text)
        let manager = ScrollbackMemoryManager(cacheDirectory: tempDirectory)

        manager.handlePhaseTransition(
            viewId: "test",
            tabID: tabID,
            rustFFI: rust,
            from: .warm,
            to: .hidden
        )
        manager.drainPendingOperationsForTesting(tabID: tabID)

        XCTAssertEqual(rust.scrollbackSizes.last, UInt32(ScrollbackRetentionPolicy.defaultHiddenViewportFloor))

        manager.handlePhaseTransition(
            viewId: "test",
            tabID: tabID,
            rustFFI: rust,
            from: .hidden,
            to: .active
        )
        manager.drainPendingOperationsForTesting(tabID: tabID)

        XCTAssertEqual(rust.replayedBuffers, [Data(text.utf8)])
    }

    func testConfiguredScrollbackApplicationRespectsCurrentRenderPhase() {
        let tabID = UUID()
        let rust = MockScrollbackRustFFI(capturedText: nil)
        let manager = ScrollbackMemoryManager(cacheDirectory: tempDirectory)

        manager.applyConfiguredScrollbackLines(
            viewId: "test",
            tabID: tabID,
            rustFFI: rust,
            phase: .hidden,
            configuredScrollbackLines: 12000
        )
        manager.drainPendingOperationsForTesting(tabID: tabID)

        manager.applyConfiguredScrollbackLines(
            viewId: "test",
            tabID: tabID,
            rustFFI: rust,
            phase: .warm,
            configuredScrollbackLines: 12000
        )
        manager.drainPendingOperationsForTesting(tabID: tabID)

        XCTAssertEqual(
            rust.scrollbackSizes,
            [
                UInt32(ScrollbackRetentionPolicy.defaultHiddenViewportFloor),
                12000
            ]
        )
    }
}

private enum TestError: Error {
    case writeFailed
}

private final class MockScrollbackRustFFI: ScrollbackMemoryRustFFI {
    private let capturedText: String?
    private(set) var scrollbackSizes: [UInt32] = []
    private(set) var replayedBuffers: [Data] = []

    init(capturedText: String?) {
        self.capturedText = capturedText
    }

    func setScrollbackSize(_ lines: UInt32) {
        scrollbackSizes.append(lines)
    }

    func captureFullBufferText() -> String? {
        capturedText
    }

    func replayBuffer(_ data: Data) {
        replayedBuffers.append(data)
    }
}
