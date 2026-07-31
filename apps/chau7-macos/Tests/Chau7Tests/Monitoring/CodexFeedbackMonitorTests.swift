import Foundation
import XCTest
@testable import Chau7

final class CodexFeedbackMonitorTests: XCTestCase {
    private var tempDirectory: URL!
    private var rolloutURL: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chau7-codex-feedback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
        rolloutURL = tempDirectory.appendingPathComponent("rollout.jsonl")
        FileManager.default.createFile(atPath: rolloutURL.path, contents: Data())
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        rolloutURL = nil
        tempDirectory = nil
    }

    func testLiveStructuredPromptAnnouncesAndResolves() throws {
        let announced = expectation(description: "structured prompt announced")
        let resolved = expectation(description: "structured prompt resolved")
        var resolvedCallID: String?

        let monitor = CodexFeedbackMonitor(
            fileURL: rolloutURL,
            debounceSeconds: 0.02,
            onPrompt: { prompt in
                XCTAssertEqual(prompt.message, "Which delivery model?")
                announced.fulfill()
            },
            onResolution: { callID, hasOtherPendingPrompt in
                resolvedCallID = callID
                XCTAssertFalse(hasOtherPendingPrompt)
                resolved.fulfill()
            }
        )
        monitor.start()

        try append(requestLine(callID: "call_live"))
        wait(for: [announced], timeout: 5)
        try append(outputLine(callID: "call_live", output: answerOutput))
        wait(for: [resolved], timeout: 5)

        XCTAssertEqual(resolvedCallID, "call_live")
        monitor.stop()
    }

    func testImmediateUnavailableResultCancelsPendingAnnouncement() throws {
        let noAnnouncement = expectation(description: "failed tool call stays silent")
        noAnnouncement.isInverted = true

        let monitor = CodexFeedbackMonitor(
            fileURL: rolloutURL,
            debounceSeconds: 0.15,
            onPrompt: { _ in noAnnouncement.fulfill() },
            onResolution: { _, _ in }
        )
        monitor.start()

        try append(requestLine(callID: "call_unavailable"))
        try append(outputLine(
            callID: "call_unavailable",
            output: "request_user_input is unavailable in Default mode"
        ))

        wait(for: [noAnnouncement], timeout: 0.6)
        monitor.stop()
    }

    func testCatchUpReconstructsAnUnresolvedPrompt() throws {
        try append(requestLine(callID: "call_existing"))
        let announced = expectation(description: "existing unresolved prompt announced")

        let monitor = CodexFeedbackMonitor(
            fileURL: rolloutURL,
            debounceSeconds: 0.02,
            onPrompt: { prompt in
                XCTAssertEqual(prompt.callID, "call_existing")
                announced.fulfill()
            },
            onResolution: { _, _ in }
        )
        monitor.start()

        wait(for: [announced], timeout: 5)
        monitor.stop()
    }

    func testCatchUpDoesNotAnnounceAnAlreadyResolvedPrompt() throws {
        try append(requestLine(callID: "call_resolved"))
        try append(outputLine(callID: "call_resolved", output: answerOutput))
        let noAnnouncement = expectation(description: "resolved prompt stays silent")
        noAnnouncement.isInverted = true

        let monitor = CodexFeedbackMonitor(
            fileURL: rolloutURL,
            debounceSeconds: 0.02,
            onPrompt: { _ in noAnnouncement.fulfill() },
            onResolution: { _, _ in }
        )
        monitor.start()

        wait(for: [noAnnouncement], timeout: 0.4)
        monitor.stop()
    }

    func testResolutionReportsWhetherAnotherPromptRemains() throws {
        let announcements = expectation(description: "both prompts announced")
        announcements.expectedFulfillmentCount = 2
        let resolutions = expectation(description: "both prompts resolved")
        resolutions.expectedFulfillmentCount = 2
        var remainingFlags: [Bool] = []

        let monitor = CodexFeedbackMonitor(
            fileURL: rolloutURL,
            debounceSeconds: 0.02,
            onPrompt: { _ in announcements.fulfill() },
            onResolution: { _, hasOtherPendingPrompt in
                remainingFlags.append(hasOtherPendingPrompt)
                resolutions.fulfill()
            }
        )
        monitor.start()
        try append(requestLine(callID: "call_one"))
        try append(requestLine(callID: "call_two"))
        wait(for: [announcements], timeout: 5)

        try append(outputLine(callID: "call_one", output: answerOutput))
        try append(outputLine(callID: "call_two", output: answerOutput))
        wait(for: [resolutions], timeout: 5)

        XCTAssertEqual(remainingFlags, [true, false])
        monitor.stop()
    }

    private var answerOutput: String {
        #"{"answers":{"delivery":{"answers":["Adapter layer"]}}}"#
    }

    private func requestLine(callID: String) throws -> String {
        let arguments = #"{"questions":[{"header":"Delivery","id":"delivery","question":"Which delivery model?","options":[{"label":"Adapter layer","description":"Decoupled"},{"label":"Direct call","description":"Coupled"}]}]}"#
        return try rolloutLine(payload: [
            "type": "function_call",
            "name": "request_user_input",
            "call_id": callID,
            "arguments": arguments
        ])
    }

    private func outputLine(callID: String, output: String) throws -> String {
        try rolloutLine(payload: [
            "type": "function_call_output",
            "call_id": callID,
            "output": output
        ])
    }

    private func rolloutLine(payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "timestamp": "2026-07-31T10:00:00Z",
            "type": "response_item",
            "payload": payload
        ], options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func append(_ line: String) throws {
        let handle = try FileHandle(forWritingTo: rolloutURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }
}
