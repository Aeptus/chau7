import Compression
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
        XCTAssertEqual(rust.ansiCaptureCount, 1, "hidden flush must use the ANSI (CRLF + SGR) capture")
        XCTAssertEqual(rust.plainCaptureCount, 0, "the bare-LF plain capture staircases on replay")

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

    func testTUIHiddenTransitionPreservesRingWithoutCaptureOrReplay() {
        let tabID = UUID()
        let rust = MockScrollbackRustFFI(capturedText: "TUI history must survive\n")
        let manager = ScrollbackMemoryManager(cacheDirectory: tempDirectory)

        manager.handlePhaseTransition(
            viewId: "test",
            tabID: tabID,
            rustFFI: rust,
            from: .warm,
            to: .hidden,
            hostsTUIApp: true
        )
        manager.handlePhaseTransition(
            viewId: "test",
            tabID: tabID,
            rustFFI: rust,
            from: .hidden,
            to: .active,
            hostsTUIApp: true
        )
        manager.drainPendingOperationsForTesting(tabID: tabID)

        XCTAssertTrue(rust.scrollbackSizes.isEmpty, "TUI ring capacity must remain untouched")
        XCTAssertEqual(rust.plainCaptureCount, 0)
        XCTAssertEqual(rust.ansiCaptureCount, 0)
        XCTAssertTrue(rust.replayedBuffers.isEmpty)
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

    func testRepeatedIdleFlushCapturesOnlyOnce() {
        let tabID = UUID()
        let rust = MockScrollbackRustFFI(capturedText: "plain\n", capturedAnsiText: "\u{1B}[32mgreen\u{1B}[0m\n")
        let manager = ScrollbackMemoryManager(cacheDirectory: tempDirectory)

        manager.idleFlush(viewId: "test", tabID: tabID, rustFFI: rust, hostsTUIApp: false)
        manager.idleFlush(viewId: "test", tabID: tabID, rustFFI: rust, hostsTUIApp: false)
        manager.drainPendingOperationsForTesting(tabID: tabID)

        XCTAssertEqual(rust.ansiCaptureCount, 1)
        XCTAssertEqual(rust.scrollbackSizes.count, 1)
    }

    func testHiddenTransitionReusesExistingIdleFlushCapture() {
        let tabID = UUID()
        let ansi = "\u{1B}[34mblue\u{1B}[0m\n"
        let rust = MockScrollbackRustFFI(capturedText: "blue\n", capturedAnsiText: ansi)
        let manager = ScrollbackMemoryManager(cacheDirectory: tempDirectory)

        manager.idleFlush(viewId: "test", tabID: tabID, rustFFI: rust, hostsTUIApp: false)
        manager.drainPendingOperationsForTesting(tabID: tabID)
        manager.handlePhaseTransition(
            viewId: "test",
            tabID: tabID,
            rustFFI: rust,
            from: .warm,
            to: .hidden
        )
        manager.drainPendingOperationsForTesting(tabID: tabID)

        XCTAssertEqual(rust.ansiCaptureCount, 1)
        XCTAssertEqual(rust.plainCaptureCount, 0)

        manager.handlePhaseTransition(
            viewId: "test",
            tabID: tabID,
            rustFFI: rust,
            from: .hidden,
            to: .active
        )
        manager.drainPendingOperationsForTesting(tabID: tabID)
        XCTAssertEqual(rust.replayedBuffers, [Data(ansi.utf8)])
    }

    // MARK: - Payload v2 (embedded size + CRC32)

    func testHighlyCompressibleBufferRoundTripsThroughFlushAndReload() {
        // ~1.3 MB of one repeated line compresses far beyond the 40× ceiling
        // that made the v1 guess-and-grow decoder fail verification, delete
        // the cache, and keep the ring resident for exactly the biggest tabs.
        let text = String(
            repeating: "The same log line repeats forever and compresses absurdly well.\r\n",
            count: 20000
        )
        let tabID = UUID()
        let rust = MockScrollbackRustFFI(capturedText: nil, capturedAnsiText: text)
        let manager = ScrollbackMemoryManager(cacheDirectory: tempDirectory)

        manager.handlePhaseTransition(
            viewId: "test",
            tabID: tabID,
            rustFFI: rust,
            from: .warm,
            to: .hidden
        )
        manager.drainPendingOperationsForTesting(tabID: tabID)

        XCTAssertEqual(
            rust.scrollbackSizes.last,
            UInt32(ScrollbackRetentionPolicy.defaultHiddenViewportFloor),
            "High-ratio buffers must pass verification and release the ring"
        )

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

    func testCorruptedCachePayloadFailsVerificationAndPreservesRing() {
        let tabID = UUID()
        let rust = MockScrollbackRustFFI(capturedText: nil, capturedAnsiText: "important history\r\n")
        let manager = ScrollbackMemoryManager(
            cacheDirectory: tempDirectory,
            cacheWriter: { payload, url in
                var corrupted = payload
                corrupted[corrupted.count - 1] ^= 0xFF
                try corrupted.write(to: url)
            }
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
            "A cache that fails checksum verification must leave the ring untouched"
        )
    }

    func testEncodedPayloadDecodesWithMatchingKindAndChecksum() {
        let data = Data("styled \u{1B}[31mline\u{1B}[0m\r\n".utf8)
        let crc = CRC32.checksum(data)
        let payload = ScrollbackMemoryManager.encodedCachePayload(for: data, contentKind: .ansi, crc32: crc)

        let decoded = ScrollbackMemoryManager.decodedCachePayload(payload)
        XCTAssertEqual(decoded?.data, data)
        XCTAssertEqual(decoded?.contentKind, .ansi)
        XCTAssertEqual(decoded?.embeddedCRC32, crc)
    }

    // MARK: - Legacy cache compatibility

    func testLegacyZlibV1CacheDecodesBeyondOldRatioCeilingAndNormalizesLineEndings() throws {
        // Legacy caches were written from the bare-LF plain capture; the
        // decoder must both survive a >40× compression ratio and CRLF-
        // normalize before parser injection (bare LFs staircase on replay).
        let text = String(repeating: "same line\n", count: 5000)
        var payload = Data("CHAU7_SCROLLBACK_ZLIB_V1\n".utf8)
        payload.append(zlibCompress(Data(text.utf8)))

        let tabID = UUID()
        try payload.write(to: tempDirectory.appendingPathComponent("\(tabID.uuidString).gz"))
        let rust = MockScrollbackRustFFI(capturedText: nil)
        let manager = ScrollbackMemoryManager(cacheDirectory: tempDirectory)

        manager.handlePhaseTransition(
            viewId: "test",
            tabID: tabID,
            rustFFI: rust,
            from: .hidden,
            to: .active
        )
        manager.drainPendingOperationsForTesting(tabID: tabID)

        let expected = String(repeating: "same line\r\n", count: 5000)
        XCTAssertEqual(rust.replayedBuffers, [Data(expected.utf8)])
    }

    func testHeaderlessLegacyTextCacheStillReplaysNormalized() throws {
        let tabID = UUID()
        try Data("one\ntwo\n".utf8).write(to: tempDirectory.appendingPathComponent("\(tabID.uuidString).gz"))
        let rust = MockScrollbackRustFFI(capturedText: nil)
        let manager = ScrollbackMemoryManager(cacheDirectory: tempDirectory)

        manager.handlePhaseTransition(
            viewId: "test",
            tabID: tabID,
            rustFFI: rust,
            from: .hidden,
            to: .active
        )
        manager.drainPendingOperationsForTesting(tabID: tabID)

        XCTAssertEqual(rust.replayedBuffers, [Data("one\r\ntwo\r\n".utf8)])
    }

    // MARK: - Flush/reload asymmetry (TUI flag flips between demotion and promotion)

    func testFlushedTabPromotedWhileTUIDefersReloadUntilSafe() {
        let tabID = UUID()
        let ansi = "shell history from before the agent started\r\n"
        let rust = MockScrollbackRustFFI(capturedText: nil, capturedAnsiText: ansi)
        let manager = ScrollbackMemoryManager(cacheDirectory: tempDirectory)

        // Flushed as a plain shell tab...
        manager.handlePhaseTransition(
            viewId: "test",
            tabID: tabID,
            rustFFI: rust,
            from: .warm,
            to: .hidden,
            hostsTUIApp: false
        )
        manager.drainPendingOperationsForTesting(tabID: tabID)
        XCTAssertEqual(rust.scrollbackSizes.last, UInt32(ScrollbackRetentionPolicy.defaultHiddenViewportFloor))

        // ...but an agent TUI is live by the time the tab is promoted: the ring
        // must grow (safe) while the replay is deferred (unsafe for a live TUI).
        manager.handlePhaseTransition(
            viewId: "test",
            tabID: tabID,
            rustFFI: rust,
            from: .hidden,
            to: .active,
            hostsTUIApp: true
        )
        manager.drainPendingOperationsForTesting(tabID: tabID)

        XCTAssertTrue(rust.replayedBuffers.isEmpty, "Never replay into a live TUI")
        XCTAssertEqual(rust.scrollbackSizes.last, UInt32(manager.linesCap(for: .active)))

        // Once the tab cycles again without a TUI, the cached history returns.
        manager.handlePhaseTransition(
            viewId: "test",
            tabID: tabID,
            rustFFI: rust,
            from: .active,
            to: .hidden,
            hostsTUIApp: true
        )
        manager.handlePhaseTransition(
            viewId: "test",
            tabID: tabID,
            rustFFI: rust,
            from: .hidden,
            to: .active,
            hostsTUIApp: false
        )
        manager.drainPendingOperationsForTesting(tabID: tabID)

        XCTAssertEqual(rust.replayedBuffers, [Data(ansi.utf8)], "Deferred cache must replay on the first safe promotion")
    }

    func testTUIDemotionThenNonTUIPromotionRestoresCapWithoutReplay() {
        let tabID = UUID()
        let rust = MockScrollbackRustFFI(capturedText: "x\n")
        let manager = ScrollbackMemoryManager(cacheDirectory: tempDirectory)

        // TUI demotion skips the flush entirely (ring stays full)...
        manager.handlePhaseTransition(
            viewId: "test",
            tabID: tabID,
            rustFFI: rust,
            from: .warm,
            to: .hidden,
            hostsTUIApp: true
        )
        // ...so a later non-TUI promotion has nothing to reload and must only
        // restore the phase cap — not skip the cap (stranding the ring) nor
        // invent a replay.
        manager.handlePhaseTransition(
            viewId: "test",
            tabID: tabID,
            rustFFI: rust,
            from: .hidden,
            to: .active,
            hostsTUIApp: false
        )
        manager.drainPendingOperationsForTesting(tabID: tabID)

        XCTAssertTrue(rust.replayedBuffers.isEmpty)
        XCTAssertEqual(rust.plainCaptureCount, 0)
        XCTAssertEqual(rust.ansiCaptureCount, 0)
        XCTAssertEqual(rust.scrollbackSizes, [UInt32(manager.linesCap(for: .active))])
    }

    // MARK: - Proactive warm-idle reclamation (Step 4)

    func testWarmPromotionReloadsIdleFlushedRing() {
        let tabID = UUID()
        let ansi = "\u{1B}[36midle history\u{1B}[0m\r\n"
        let rust = MockScrollbackRustFFI(capturedText: nil, capturedAnsiText: ansi)
        let manager = ScrollbackMemoryManager(cacheDirectory: tempDirectory)

        manager.idleFlush(viewId: "test", tabID: tabID, rustFFI: rust, hostsTUIApp: false, bytesReceivedAtFlush: 100)
        manager.drainPendingOperationsForTesting(tabID: tabID)
        XCTAssertEqual(rust.scrollbackSizes.last, UInt32(ScrollbackRetentionPolicy.defaultHiddenViewportFloor))

        // warm → active is NOT a hidden reload transition; the promotion path
        // must still restore the idle-flushed history from disk.
        manager.handlePhaseTransition(
            viewId: "test",
            tabID: tabID,
            rustFFI: rust,
            from: .warm,
            to: .active,
            hostsTUIApp: false,
            currentBytesReceived: 100
        )
        manager.drainPendingOperationsForTesting(tabID: tabID)

        XCTAssertEqual(rust.replayedBuffers, [Data(ansi.utf8)], "Unchanged byte counter → replay the cache alone")
        XCTAssertEqual(rust.scrollbackSizes.last, UInt32(manager.linesCap(for: .active)))
    }

    func testReloadAppendsSeamCaptureWhenOutputArrivedAfterFlush() {
        let tabID = UUID()
        let ansi = "old history\r\n"
        let rust = MockScrollbackRustFFI(capturedText: nil, capturedAnsiText: ansi)
        let manager = ScrollbackMemoryManager(cacheDirectory: tempDirectory)

        manager.idleFlush(viewId: "test", tabID: tabID, rustFFI: rust, hostsTUIApp: false, bytesReceivedAtFlush: 100)
        manager.drainPendingOperationsForTesting(tabID: tabID)

        manager.handlePhaseTransition(
            viewId: "test",
            tabID: tabID,
            rustFFI: rust,
            from: .warm,
            to: .active,
            hostsTUIApp: false,
            currentBytesReceived: 150
        )
        manager.drainPendingOperationsForTesting(tabID: tabID)

        var expected = Data(ansi.utf8)
        expected.append(Data("\u{1B}[0m".utf8))
        expected.append(Data(ansi.utf8)) // mock returns the same capture for the seam
        XCTAssertEqual(
            rust.replayedBuffers,
            [expected],
            "Output after the flush must be captured and replayed after the cache — never dropped"
        )
    }

    func testIdleFlushGateRequiresQuietPTYAndWarmPhase() {
        XCTAssertTrue(ScrollbackRetentionPolicy.shouldIdleFlush(
            phase: .warm, bytesReceivedWhenArmed: 10, bytesReceivedNow: 10
        ))
        XCTAssertFalse(ScrollbackRetentionPolicy.shouldIdleFlush(
            phase: .warm, bytesReceivedWhenArmed: 10, bytesReceivedNow: 42
        ), "Streaming tab must not flush")
        XCTAssertFalse(ScrollbackRetentionPolicy.shouldIdleFlush(
            phase: .active, bytesReceivedWhenArmed: 10, bytesReceivedNow: 10
        ), "Only .warm tabs flush")
        XCTAssertFalse(ScrollbackRetentionPolicy.shouldIdleFlush(
            phase: .warm, bytesReceivedWhenArmed: nil, bytesReceivedNow: nil
        ), "Missing byte counters fail closed")
    }

    func testScrollbackBudgetFlushesLargestCandidatesFirst() {
        let manager = ScrollbackMemoryManager(cacheDirectory: tempDirectory)
        var flushed: [String] = []
        manager.registerBudgetFlushCandidate(
            tabID: UUID(),
            candidate: ScrollbackBudgetFlushCandidate(
                viewId: "small",
                estimatedRingBytes: { 10_000_000 },
                requestFlush: { flushed.append("small") }
            )
        )
        manager.registerBudgetFlushCandidate(
            tabID: UUID(),
            candidate: ScrollbackBudgetFlushCandidate(
                viewId: "large",
                estimatedRingBytes: { 400_000_000 },
                requestFlush: { flushed.append("large") }
            )
        )

        manager.enforceScrollbackBudget(budgetBytes: 100_000_000, perTabBudgetBytes: 500_000_000)
        XCTAssertEqual(flushed, ["large"], "Largest candidate flushes first; small stays once under budget")

        flushed.removeAll()
        manager.enforceScrollbackBudget(budgetBytes: 500_000_000, perTabBudgetBytes: 500_000_000)
        XCTAssertTrue(flushed.isEmpty, "Under budget → nothing flushes")
    }

    func testPerTabScrollbackBudgetFlushesOversizedWarmCandidateUnderAggregateBudget() {
        let manager = ScrollbackMemoryManager(cacheDirectory: tempDirectory)
        var flushed = false
        manager.registerBudgetFlushCandidate(
            tabID: UUID(),
            candidate: ScrollbackBudgetFlushCandidate(
                viewId: "oversized",
                estimatedRingBytes: { 65 * 1_024 * 1_024 },
                requestFlush: { flushed = true }
            )
        )

        manager.enforceScrollbackBudget(
            budgetBytes: 500 * 1_024 * 1_024,
            perTabBudgetBytes: 64 * 1_024 * 1_024
        )

        XCTAssertTrue(flushed, "A single warm tab must not consume most of the aggregate budget")
    }

    // MARK: - TUI compaction (Step 5): capture-if-safe, shrink-always, replay-never while protected

    func testTUICompactOnAltScreenShrinksOnlyWithoutCaptureOrReplay() {
        let tabID = UUID()
        let rust = MockScrollbackRustFFI(capturedText: nil, capturedAnsiText: "alt screen surface\r\n")
        let manager = ScrollbackMemoryManager(cacheDirectory: tempDirectory)

        manager.tuiIdleCompact(
            viewId: "test",
            tabID: tabID,
            rustFFI: rust,
            isOnAlternateScreen: true,
            bytesReceivedAtFlush: 100
        )
        manager.drainPendingOperationsForTesting(tabID: tabID)

        XCTAssertEqual(rust.scrollbackSizes, [UInt32(ScrollbackRetentionPolicy.tuiWarmTierLines)])
        XCTAssertEqual(rust.ansiCaptureCount, 0, "Alt-screen primary grid is uncapturable; shrink-only")
        XCTAssertTrue(rust.replayedBuffers.isEmpty)

        // Later promotion: nothing on disk → just the phase cap, never a replay.
        manager.handlePhaseTransition(
            viewId: "test",
            tabID: tabID,
            rustFFI: rust,
            from: .warm,
            to: .active,
            hostsTUIApp: true
        )
        manager.drainPendingOperationsForTesting(tabID: tabID)
        XCTAssertTrue(rust.replayedBuffers.isEmpty)
        XCTAssertEqual(rust.scrollbackSizes.last, UInt32(manager.linesCap(for: .active)))
    }

    func testTUICompactOnPrimaryScreenPersistsAndDefersReplayUntilUnprotected() {
        let tabID = UUID()
        let ansi = "claude transcript history\r\n"
        let rust = MockScrollbackRustFFI(capturedText: nil, capturedAnsiText: ansi)
        let manager = ScrollbackMemoryManager(cacheDirectory: tempDirectory)

        manager.tuiIdleCompact(
            viewId: "test",
            tabID: tabID,
            rustFFI: rust,
            isOnAlternateScreen: false,
            bytesReceivedAtFlush: 100
        )
        manager.drainPendingOperationsForTesting(tabID: tabID)

        XCTAssertEqual(rust.ansiCaptureCount, 1, "Primary-screen capture is read-only and safe")
        XCTAssertEqual(rust.scrollbackSizes.last, UInt32(ScrollbackRetentionPolicy.tuiWarmTierLines))

        // Promotion while the agent TUI is still live: grow the ring, never replay.
        manager.handlePhaseTransition(
            viewId: "test",
            tabID: tabID,
            rustFFI: rust,
            from: .warm,
            to: .active,
            hostsTUIApp: true,
            currentBytesReceived: 100
        )
        manager.drainPendingOperationsForTesting(tabID: tabID)
        XCTAssertTrue(rust.replayedBuffers.isEmpty, "NEVER replay into a live TUI")
        XCTAssertEqual(rust.scrollbackSizes.last, UInt32(manager.linesCap(for: .active)))

        // Agent exits; the next promotion cycle restores the deep history.
        manager.handlePhaseTransition(
            viewId: "test",
            tabID: tabID,
            rustFFI: rust,
            from: .active,
            to: .warm,
            hostsTUIApp: false,
            currentBytesReceived: 100
        )
        manager.handlePhaseTransition(
            viewId: "test",
            tabID: tabID,
            rustFFI: rust,
            from: .warm,
            to: .active,
            hostsTUIApp: false,
            currentBytesReceived: 100
        )
        manager.drainPendingOperationsForTesting(tabID: tabID)
        XCTAssertEqual(rust.replayedBuffers, [Data(ansi.utf8)], "History returns once the TUI protection clears")
    }

    // MARK: - Helpers

    private func zlibCompress(_ data: Data) -> Data {
        data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data in
            let srcBase = src.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let dstCapacity = data.count + data.count / 10 + 256
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCapacity)
            defer { dst.deallocate() }
            let written = compression_encode_buffer(
                dst, dstCapacity,
                srcBase, data.count,
                nil,
                COMPRESSION_ZLIB
            )
            return Data(bytes: dst, count: written)
        }
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
