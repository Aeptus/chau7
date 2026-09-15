import XCTest
@testable import Chau7Core

final class MainThreadHangMonitorTests: XCTestCase {
    private let policy = MainThreadHangMonitorPolicy(
        stallThreshold: 2,
        sampleThreshold: 4,
        sampleCooldown: 60
    )

    func testProgressKeepsMonitorHealthy() {
        var state = MainThreadHangMonitorState(initialProgressToken: 1, now: 100)

        let observation = state.observe(progressToken: 2, now: 101, policy: policy)

        XCTAssertEqual(observation.phase, .healthy)
        XCTAssertFalse(observation.enteredStall)
        XCTAssertFalse(observation.recovered)
        XCTAssertFalse(observation.shouldSample)
    }

    func testStallOpensBeforeIndependentSampleBecomesDue() {
        var state = MainThreadHangMonitorState(initialProgressToken: 7, now: 100)

        let stalled = state.observe(progressToken: 7, now: 102, policy: policy)
        let sampled = state.observe(progressToken: 7, now: 104, policy: policy)
        let repeated = state.observe(progressToken: 7, now: 180, policy: policy)

        XCTAssertTrue(stalled.enteredStall)
        XCTAssertFalse(stalled.shouldSample)
        XCTAssertFalse(sampled.enteredStall)
        XCTAssertTrue(sampled.shouldSample)
        XCTAssertFalse(repeated.shouldSample, "a single stall must produce only one sample")
    }

    func testProgressClosesStallAndReportsItsDuration() {
        var state = MainThreadHangMonitorState(initialProgressToken: 3, now: 50)
        _ = state.observe(progressToken: 3, now: 52, policy: policy)

        let recovered = state.observe(progressToken: 4, now: 55.5, policy: policy)

        XCTAssertEqual(recovered.phase, .healthy)
        XCTAssertTrue(recovered.recovered)
        XCTAssertEqual(recovered.staleFor, 5.5, accuracy: 0.001)
    }

    func testSampleCooldownCarriesAcrossSeparateStalls() {
        var state = MainThreadHangMonitorState(initialProgressToken: 1, now: 0)
        XCTAssertTrue(state.observe(progressToken: 1, now: 4, policy: policy).shouldSample)
        _ = state.observe(progressToken: 2, now: 5, policy: policy)
        _ = state.observe(progressToken: 2, now: 9, policy: policy)

        XCTAssertFalse(state.observe(progressToken: 2, now: 63, policy: policy).shouldSample)
        XCTAssertTrue(state.observe(progressToken: 2, now: 64, policy: policy).shouldSample)
    }

    func testClockRollbackDoesNotCreateNegativeStaleness() {
        var state = MainThreadHangMonitorState(initialProgressToken: 1, now: 100)

        let observation = state.observe(progressToken: 1, now: 90, policy: policy)

        XCTAssertEqual(observation.staleFor, 0)
        XCTAssertEqual(observation.phase, .healthy)
    }

    func testWatchdogCommandRequiresCompleteValidatedArguments() {
        XCTAssertEqual(
            MainThreadHangWatchdogCommand.parse(arguments: [
                "Chau7",
                "--hang-watchdog",
                "--parent-pid", "123",
                "--heartbeat", "/tmp/chau7 heartbeat.json",
                "--output-directory", "/tmp/chau7 hangs"
            ]),
            MainThreadHangWatchdogCommand(
                parentPID: 123,
                heartbeatPath: "/tmp/chau7 heartbeat.json",
                outputDirectoryPath: "/tmp/chau7 hangs"
            )
        )
        XCTAssertNil(MainThreadHangWatchdogCommand.parse(arguments: [
            "Chau7", "--hang-watchdog", "--parent-pid", "123"
        ]))
        XCTAssertNil(MainThreadHangWatchdogCommand.parse(arguments: [
            "Chau7",
            "--hang-watchdog",
            "--parent-pid", "0",
            "--heartbeat", "relative.json",
            "--output-directory", "/tmp"
        ]))
    }
}
