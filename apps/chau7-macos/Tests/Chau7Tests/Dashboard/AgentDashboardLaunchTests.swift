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
