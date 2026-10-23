import XCTest
@testable import Chau7Core

final class RemotePromptDetectionCacheTests: XCTestCase {
    private let firstChoice = "Do you want to proceed?\n❯ 1. Yes\n  2. No"
    private let secondChoice = "Do you want to proceed?\n  1. Yes\n❯ 2. No"
    private let revision = RemotePromptDetectionCache.Revision(outputVersion: 1, lastInputAt: .distantPast)

    func testUnchangedPromptIsCapturedOnlyOnceAcross240Refreshes() {
        var cache = RemotePromptDetectionCache()
        var captures = 0
        for _ in 0 ..< 240 {
            let result = cache.detection(sessionID: "pane", revision: revision, toolName: "Codex") {
                captures += 1
                return firstChoice
            }
            XCTAssertEqual(result?.options.count, 2)
        }
        XCTAssertEqual(captures, 1)
    }

    func testNegativeDetectionsIncludingMissingTailsAreCached() {
        for text in [nil, "ordinary output"] as [String?] {
            var cache = RemotePromptDetectionCache()
            var captures = 0
            for _ in 0 ..< 3 {
                XCTAssertNil(cache.detection(sessionID: "pane", revision: revision, toolName: "Claude") {
                    captures += 1
                    return text
                })
            }
            XCTAssertEqual(captures, 1)
        }
    }

    func testOutputImmediatelyRefreshesCursorResponsesWithoutChangingPromptIdentity() throws {
        for provider in ["Claude", "Codex"] {
            var cache = RemotePromptDetectionCache()
            let first = try XCTUnwrap(cache.detection(sessionID: "pane", revision: revision, toolName: provider) { firstChoice })
            let second = try XCTUnwrap(cache.detection(
                sessionID: "pane", revision: .init(outputVersion: 2, lastInputAt: .distantPast), toolName: provider
            ) { secondChoice })
            XCTAssertEqual(first.signature, second.signature)
            XCTAssertEqual(first.options[0].response, "\r")
            XCTAssertEqual(second.options[0].response, "\u{1B}[A\r")
            XCTAssertEqual(second.options[1].response, "\r")
        }
    }

    func testInputProviderAndTerminalReplacementEachInvalidate() {
        var cache = RemotePromptDetectionCache()
        let terminal = NSObject()
        let changedInput = RemotePromptDetectionCache.Revision(outputVersion: 1, lastInputAt: .distantFuture)
        let changedTerminal = RemotePromptDetectionCache.Revision(
            outputVersion: 1, lastInputAt: .distantFuture, terminalIdentity: ObjectIdentifier(terminal)
        )
        var captures = 0
        for (revision, provider) in [(revision, "Codex"), (changedInput, "Codex"), (changedInput, "Claude"), (changedTerminal, "Claude")] {
            _ = cache.detection(sessionID: "pane", revision: revision, toolName: provider) {
                captures += 1
                return firstChoice
            }
        }
        XCTAssertEqual(captures, 4)
    }

    func testDifferentSessionsCannotShareAPrompt() {
        var cache = RemotePromptDetectionCache()
        XCTAssertNotNil(cache.detection(sessionID: "one", revision: revision, toolName: "Codex") { firstChoice })
        XCTAssertNil(cache.detection(sessionID: "two", revision: revision, toolName: "Codex") { nil })
    }

    func testCapacityEvictsLeastRecentlyUsedSession() {
        var cache = RemotePromptDetectionCache(capacity: 2)
        for sessionID in ["one", "two", "one", "three"] {
            _ = cache.detection(sessionID: sessionID, revision: revision, toolName: "Codex") { firstChoice }
        }
        _ = cache.detection(sessionID: "one", revision: revision, toolName: "Codex") {
            XCTFail("Recently used session should remain cached")
            return nil
        }
        var recaptured = false
        _ = cache.detection(sessionID: "two", revision: revision, toolName: "Codex") {
            recaptured = true
            return nil
        }
        XCTAssertTrue(recaptured)
    }

    func testDisconnectClearsDetections() {
        var cache = RemotePromptDetectionCache()
        _ = cache.detection(sessionID: "pane", revision: revision, toolName: "Codex") { firstChoice }
        cache.removeAll()
        XCTAssertNil(cache.detection(sessionID: "pane", revision: revision, toolName: "Codex") { nil })
    }
}
