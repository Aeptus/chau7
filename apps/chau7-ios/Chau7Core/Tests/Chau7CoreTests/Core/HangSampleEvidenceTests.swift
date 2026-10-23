import Foundation
import XCTest
@testable import Chau7Core

final class HangSampleEvidenceTests: XCTestCase {
    func testRecoveryDuringSampleIsExplicitAndRolloverCountsAsProgress() {
        let evidence = HangSampleEvidence(beforeToken: UInt64.max, afterToken: 0, startedUptime: 10, completedUptime: 15)
        XCTAssertEqual(evidence.heartbeatProgressDuringCapture, .advanced)
        XCTAssertEqual(evidence.captureDurationSeconds, 5)
    }

    func testUnchangedTokensAndMissingHeartbeatStayDistinct() {
        XCTAssertEqual(HangSampleEvidence(beforeToken: 1, afterToken: 1, startedUptime: 10, completedUptime: 15).heartbeatProgressDuringCapture, .unchanged)
        let unavailable = HangSampleEvidence(beforeToken: 1, afterToken: nil, startedUptime: 10, completedUptime: 9)
        XCTAssertEqual(unavailable.heartbeatProgressDuringCapture, .unavailable)
        XCTAssertEqual(unavailable.captureDurationSeconds, 0)
    }

    func testObjectiveCTeardownIsRecordedOnlyFromMainThread() {
        let sample = """
        Call graph:
            557 Thread_10554 DispatchQueue_1: com.apple.main-thread (serial)
            + 557 _Block_release
            + ! 557 objc_destructInstance
            + ! : 557 _object_remove_associations
            557 Thread_11111 DispatchQueue_2: background
            + 557 NSAlert.runModal
        """
        let observations = MainThreadStackObservations(sampleText: sample)
        XCTAssertTrue(observations.mainThreadFound)
        XCTAssertEqual(observations.mainThreadSampleCount, 557)
        XCTAssertEqual(observations.observedFamilies, [.objectiveCBlockTeardown])
    }

    func testBackgroundTeardownDoesNotExplainMainLayout() {
        let sample = """
            10 Thread_1 DispatchQueue_1: com.apple.main-thread (serial)
            + 10 NSHostingView.layout
            10 Thread_2 DispatchQueue_2: background
            + 10 _Block_release objc_destructInstance _object_remove_associations
        """
        XCTAssertEqual(MainThreadStackObservations(sampleText: sample).observedFamilies, [.viewLayout])
    }

    func testModalAndTeardownFamiliesCanCoexistWithoutRootCauseRanking() {
        let sample = """
            10 Thread_1 DispatchQueue_1: com.apple.main-thread (serial)
            + 10 NSAlert.runModal
            + 1 _Block_release objc_destructInstance _object_remove_associations
        """
        XCTAssertEqual(MainThreadStackObservations(sampleText: sample).observedFamilies, [.objectiveCBlockTeardown, .modalDialog])
    }

    func testGenericBlockReleaseDoesNotCountAsAssociatedObjectTeardown() {
        let sample = """
            10 Thread_1 DispatchQueue_1: com.apple.main-thread (serial)
            + 10 _Block_release
        """
        XCTAssertEqual(MainThreadStackObservations(sampleText: sample).observedFamilies, [])
    }

    func testAbsentMainThreadAndTruncationAreExplicit() {
        let missing = MainThreadStackObservations(sampleText: "sample failed")
        XCTAssertFalse(missing.mainThreadFound)
        XCTAssertNil(missing.mainThreadSampleCount)
        let oversized = String(repeating: "x", count: MainThreadStackObservations.maximumInputBytes + 1)
        let truncated = MainThreadStackObservations(sampleText: oversized)
        XCTAssertTrue(truncated.inputTruncated)
        XCTAssertFalse(truncated.mainThreadFound)
    }

    func testEvidenceRoundTripsInManifest() throws {
        let evidence = HangSampleEvidence(beforeToken: 1, afterToken: 2, startedUptime: 0, completedUptime: 1)
        XCTAssertEqual(try JSONDecoder().decode(HangSampleEvidence.self, from: JSONEncoder().encode(evidence)), evidence)
    }
}
