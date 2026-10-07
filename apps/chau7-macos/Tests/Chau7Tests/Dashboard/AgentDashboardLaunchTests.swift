import XCTest
@testable import Chau7

@MainActor
final class AgentDashboardLaunchTests: XCTestCase {
    func testLaunchFromMainRunsSessionCreationOnWorker() async {
        let launched = expectation(description: "worker launch")
        let controller = LaunchController { arguments in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertEqual(arguments["backend"] as? String, "codex")
            XCTAssertEqual(arguments["directory"] as? String, "/tmp/repo")
            XCTAssertEqual(MainActorBridge.sync { "main-progress" }, "main-progress")
            launched.fulfill()
            return "{}"
        }
        let model = AgentDashboardModel(repoGroupID: "/tmp/repo", sessionController: controller)
        model.startAgent(backend: "codex", model: nil, prompt: nil, autoApprove: false)
        await fulfillment(of: [launched], timeout: 2)
        withExtendedLifetime(model) {}
    }

    func testReviewFromMainRunsSessionCreationOnWorker() async {
        let launched = expectation(description: "worker review")
        let controller = LaunchController { arguments in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertEqual(arguments["purpose"] as? String, "code_review")
            XCTAssertEqual(MainActorBridge.sync { "main-progress" }, "main-progress")
            launched.fulfill()
            return "{}"
        }
        let model = AgentDashboardModel(repoGroupID: "/tmp/repo", sessionController: controller)
        model.startCodeReview(
            baseCommit: "base",
            headCommit: "head",
            parentSessionID: nil,
            model: nil,
            extraInstructions: nil,
            autoApprove: false
        )
        await fulfillment(of: [launched], timeout: 2)
        withExtendedLifetime(model) {}
    }

    func testFailedReviewKeepsSheetOpenUntilWorkerResultAndShowsError() async {
        let finished = expectation(description: "failed review completes on main")
        let controller = LaunchController { _ in
            XCTAssertFalse(Thread.isMainThread)
            return "{\"error\":\"Tab control denied by user.\"}"
        }
        let model = AgentDashboardModel(repoGroupID: "/tmp/repo", sessionController: controller)
        model.showReviewSheet = true
        model.startCodeReview(
            baseCommit: "base", headCommit: "head", parentSessionID: nil,
            model: nil, extraInstructions: "retain these instructions", autoApprove: false
        ) { success in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertFalse(success)
            finished.fulfill()
        }
        XCTAssertTrue(model.showReviewSheet)
        XCTAssertTrue(model.isLaunchingReview)
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertTrue(model.showReviewSheet)
        XCTAssertFalse(model.isLaunchingReview)
        XCTAssertEqual(model.reviewError, "Tab control denied by user.")
    }

    func testSuccessfulReviewDismissesOnlyAfterWorkerCompletesAndRejectsDuplicateLaunch() async {
        let finished = expectation(description: "successful review completes on main")
        var launchCount = 0
        let controller = LaunchController { _ in
            MainActorBridge.sync { launchCount += 1 }
            return "{}"
        }
        let model = AgentDashboardModel(repoGroupID: "/tmp/repo", sessionController: controller)
        model.showReviewSheet = true
        model.startCodeReview(
            baseCommit: "base", headCommit: "head", parentSessionID: nil,
            model: nil, extraInstructions: nil, autoApprove: false
        ) { success in
            XCTAssertTrue(success)
            finished.fulfill()
        }
        model.startCodeReview(
            baseCommit: "other", headCommit: "other", parentSessionID: nil,
            model: nil, extraInstructions: nil, autoApprove: false
        ) { success in XCTAssertFalse(success) }
        XCTAssertTrue(model.showReviewSheet)
        XCTAssertTrue(model.isLaunchingReview)
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(launchCount, 1)
        XCTAssertFalse(model.showReviewSheet)
        XCTAssertFalse(model.isLaunchingReview)
        XCTAssertNil(model.reviewError)
    }

    func testInvalidReviewKeepsSheetOpenWithoutStartingWorker() {
        let model = AgentDashboardModel(repoGroupID: "/tmp/repo", sessionController: LaunchController { _ in
            XCTFail("Invalid commit fields must not start a worker")
            return "{}"
        })
        model.showReviewSheet = true
        model.startCodeReview(
            baseCommit: " ", headCommit: "head", parentSessionID: nil,
            model: nil, extraInstructions: nil, autoApprove: false
        ) { success in XCTAssertFalse(success) }
        XCTAssertTrue(model.showReviewSheet)
        XCTAssertFalse(model.isLaunchingReview)
        XCTAssertEqual(model.reviewError, "Base and head commits are required.")
    }

}

private final class LaunchController: AgentDashboardSessionControlling {
    let launch: ([String: Any]) -> String
    init(_ launch: @escaping ([String: Any]) -> String) {
        self.launch = launch
    }

    func allSessions(includeStopped _: Bool) -> [DashboardSessionSnapshot] {
        []
    }

    func stopSession(id _: String) -> Bool {
        false
    }

    func startSession(arguments: [String: Any]) -> String {
        launch(arguments)
    }
}
