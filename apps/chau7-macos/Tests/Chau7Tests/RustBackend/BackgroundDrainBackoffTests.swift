import XCTest
@testable import Chau7

final class BackgroundDrainBackoffTests: XCTestCase {
    func testActiveOrRecentlyActiveViewPollsEveryTick() {
        for tick in 1 ... 20 {
            XCTAssertTrue(BackgroundDrainBackoff.shouldPoll(idleStreak: 0, tick: tick))
            XCTAssertTrue(BackgroundDrainBackoff.shouldPoll(idleStreak: 2, tick: tick))
        }
    }

    func testStrideGrowsWithIdleStreakAndCaps() {
        XCTAssertEqual(BackgroundDrainBackoff.stride(forIdleStreak: 0), 1)
        XCTAssertEqual(BackgroundDrainBackoff.stride(forIdleStreak: 2), 1)
        XCTAssertEqual(BackgroundDrainBackoff.stride(forIdleStreak: 3), 2)
        XCTAssertEqual(BackgroundDrainBackoff.stride(forIdleStreak: 4), 3)
        XCTAssertEqual(
            BackgroundDrainBackoff.stride(forIdleStreak: 100),
            BackgroundDrainBackoff.maxStride
        )
    }

    func testDormantViewPollsOncePerStride() {
        // idleStreak 3 → stride 2 → only even ticks
        let shallow = (1 ... 8).filter { BackgroundDrainBackoff.shouldPoll(idleStreak: 3, tick: $0) }
        XCTAssertEqual(shallow, [2, 4, 6, 8])

        // deeply idle → capped stride (8) → once every 8 ticks
        let deep = (1 ... 16).filter { BackgroundDrainBackoff.shouldPoll(idleStreak: 100, tick: $0) }
        XCTAssertEqual(deep, [8, 16])
    }

    func testHiddenDrainDoesNotScheduleVisibleBufferCallback() {
        XCTAssertFalse(BackgroundDrainDeliveryPolicy.shouldNotifyBufferChanged(
            gridChanged: true,
            allowsLivePresentation: false
        ))
        XCTAssertTrue(BackgroundDrainDeliveryPolicy.shouldNotifyBufferChanged(
            gridChanged: true,
            allowsLivePresentation: true
        ))
        XCTAssertFalse(BackgroundDrainDeliveryPolicy.shouldNotifyBufferChanged(
            gridChanged: false,
            allowsLivePresentation: true
        ))
    }

    func testDrainOnlyPresentationSkipsGridSnapshots() {
        XCTAssertFalse(TerminalGridSnapshotPolicy.allowsPresentationSnapshot(visibility: "drainOnly"))
        XCTAssertTrue(TerminalGridSnapshotPolicy.allowsPresentationSnapshot(visibility: "visible"))
        XCTAssertTrue(TerminalGridSnapshotPolicy.allowsPresentationSnapshot(visibility: "windowHidden"))
    }

    func testBackgroundSnapshotMovesBackendReadDurationOffMainThread() throws {
        let view = RustTerminalView(frame: .zero)
        view.hasLoggedStartupActivity = true
        view.hasObservedInitialPTYActivity = true
        let fake = FakeTerminalBackend()
        fake.backendReadDelay = 0.002
        let output = Data("background output\n".utf8)
        let profiler = TerminalWorkProfiler.shared

        profiler.resetForTesting()
        fake.nextOutput = output
        view.terminalPollAccessLock.lock()
        _ = view.processTerminalStateAfterPollLocked(
            rust: fake,
            changed: true,
            caller: "beforeSplit"
        )
        view.terminalPollAccessLock.unlock()
        let beforeContext = view.terminalWorkContext(caller: "beforeSplit")
        let beforeExtraction = profiler.snapshot().entries[
            TerminalWorkProfiler.Key(
                operation: .terminalStateExtraction,
                context: beforeContext
            )
        ]?.mainThreadDurationMs ?? 0

        profiler.resetForTesting()
        fake.nextOutput = output
        let box = TerminalDrainSnapshotBox()
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            view.terminalPollAccessLock.lock()
            let snapshot = view.extractTerminalDrainSnapshotLocked(
                rust: fake,
                changed: true,
                caller: "backgroundDrain"
            )
            view.terminalPollAccessLock.unlock()
            box.store(snapshot)
            completed.signal()
        }
        XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
        let snapshot = try XCTUnwrap(box.load())
        _ = view.applyTerminalDrainSnapshot(
            snapshot,
            rust: fake,
            backendLockHeld: false
        )
        let afterSnapshot = profiler.snapshot()
        let extractionKey = TerminalWorkProfiler.Key(
            operation: .terminalStateExtraction,
            context: snapshot.profileContext
        )
        let processingKey = TerminalWorkProfiler.Key(
            operation: .terminalStateProcessing,
            context: snapshot.profileContext
        )
        let afterApply = afterSnapshot.entries[processingKey]?.mainThreadDurationMs ?? 0

        Log.info(String(
            format: "Terminal drain synthetic before/after: main backend extraction %.2fms -> %.2fms; main apply %.2fms",
            beforeExtraction,
            afterSnapshot.entries[extractionKey]?.mainThreadDurationMs ?? 0,
            afterApply
        ))

        XCTAssertEqual(fake.lastOutputReadOnMainThread, false)
        XCTAssertEqual(fake.cursorModeReadOnMainThread, false)
        XCTAssertEqual(afterSnapshot.entries[extractionKey]?.mainThreadDurationMs, 0)
        XCTAssertGreaterThan(beforeExtraction, 3.5)
        XCTAssertLessThan(afterApply, beforeExtraction)
    }
}

private final class TerminalDrainSnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: TerminalDrainSnapshot?

    func store(_ snapshot: TerminalDrainSnapshot) {
        lock.lock()
        self.snapshot = snapshot
        lock.unlock()
    }

    func load() -> TerminalDrainSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }
}
