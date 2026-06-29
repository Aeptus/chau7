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

    // MARK: - Idle flush (phase-independent, opt-in)

    func testIdleFlushCapturesAnsiShrinksRingAndReloadsLossless() {
        let tabID = UUID()
        let ansi = "\u{1B}[31mred\u{1B}[0m\nplain\n"
        let rust = MockScrollbackRustFFI(capturedText: "red\nplain\n", capturedAnsiText: ansi)
        let manager = ScrollbackMemoryManager(cacheDirectory: tempDirectory)

        manager.idleFlush(viewId: "test", tabID: tabID, rustFFI: rust, hostsTUIApp: false)
        manager.drainPendingOperationsForTesting(tabID: tabID)

        XCTAssertEqual(rust.ansiCaptureCount, 1, "idle flush must use the ANSI (lossless) capture")
        XCTAssertEqual(rust.plainCaptureCount, 0, "idle flush must NOT use the plain capture")
        XCTAssertEqual(rust.scrollbackSizes.last, UInt32(ScrollbackRetentionPolicy.defaultHiddenViewportFloor))

        manager.idleReloadIfNeeded(viewId: "test", tabID: tabID, rustFFI: rust, configuredLines: 10000)
        manager.drainPendingOperationsForTesting(tabID: tabID)

        XCTAssertEqual(rust.replayedBuffers, [Data(ansi.utf8)], "reload must replay the ANSI buffer (colors preserved)")
        XCTAssertEqual(rust.scrollbackSizes.last, 10000, "ring restored to configured capacity on reload")
    }

    func testIdleFlushSkipsTUITabs() {
        let tabID = UUID()
        let rust = MockScrollbackRustFFI(capturedText: "x\n")
        let manager = ScrollbackMemoryManager(cacheDirectory: tempDirectory)

        manager.idleFlush(viewId: "test", tabID: tabID, rustFFI: rust, hostsTUIApp: true)
        manager.drainPendingOperationsForTesting(tabID: tabID)

        XCTAssertEqual(rust.ansiCaptureCount, 0, "TUI tabs must never be flattened/flushed")
        XCTAssertTrue(rust.scrollbackSizes.isEmpty, "TUI tab ring left untouched")
    }

    func testIdleReloadIsNoOpWhenNotFlushed() {
        let tabID = UUID()
        let rust = MockScrollbackRustFFI(capturedText: "x\n")
        let manager = ScrollbackMemoryManager(cacheDirectory: tempDirectory)

        manager.idleReloadIfNeeded(viewId: "test", tabID: tabID, rustFFI: rust, configuredLines: 10000)
        manager.drainPendingOperationsForTesting(tabID: tabID)

        XCTAssertTrue(rust.replayedBuffers.isEmpty, "reload must be a no-op for tabs that weren't idle-flushed")
    }
}

private enum TestError: Error {
    case writeFailed
}

private final class MockScrollbackRustFFI: ScrollbackMemoryRustFFI {
    private let capturedText: String?
    private let capturedAnsiText: String?
    private(set) var scrollbackSizes: [UInt32] = []
    private(set) var replayedBuffers: [Data] = []
    private(set) var plainCaptureCount = 0
    private(set) var ansiCaptureCount = 0

    init(capturedText: String?, capturedAnsiText: String? = nil) {
        self.capturedText = capturedText
        self.capturedAnsiText = capturedAnsiText ?? capturedText
    }

    func setScrollbackSize(_ lines: UInt32) {
        scrollbackSizes.append(lines)
    }

    func captureFullBufferText() -> String? {
        plainCaptureCount += 1
        return capturedText
    }

    func captureFullBufferAnsiText() -> String? {
        ansiCaptureCount += 1
        return capturedAnsiText
    }

    func replayBuffer(_ data: Data) {
        replayedBuffers.append(data)
    }
}
