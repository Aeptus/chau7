import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7

final class RepositoryCacheTests: XCTestCase {
    func testResolveDiscoversNestedRepositoryAfterParentWasCached() {
        let cache = RepositoryCache(
            gitRunner: { args, directory in
                XCTAssertEqual(args, ["rev-parse", "--show-toplevel", "--abbrev-ref", "HEAD"])
                switch directory {
                case "/repos/main":
                    return "/repos/main\nmain"
                case "/repos/main/submodule/worktree":
                    return "/repos/main/submodule\nfeature/submodule"
                default:
                    return ""
                }
            },
            recentRepoRecorder: { _ in }
        )

        let parentExpectation = expectation(description: "parent repo resolved")
        cache.resolve(path: "/repos/main") { model in
            XCTAssertEqual(model?.rootPath, "/repos/main")
            parentExpectation.fulfill()
        }
        wait(for: [parentExpectation], timeout: 1.0)

        let nestedExpectation = expectation(description: "nested repo resolved")
        cache.resolve(path: "/repos/main/submodule/worktree") { model in
            XCTAssertEqual(model?.rootPath, "/repos/main/submodule")
            XCTAssertEqual(model?.branch, "feature/submodule")
            nestedExpectation.fulfill()
        }
        wait(for: [nestedExpectation], timeout: 1.0)

        XCTAssertEqual(cache.cachedRepoCount, 2)
    }

    func testRefreshBranchCoalescesRapidCalls() {
        let runnerCalls = LockedCounter()
        let model = RepositoryModel(
            rootPath: "/repos/main",
            branch: "main",
            gitRunner: { _, _ in
                runnerCalls.increment()
                return "main"
            },
            refreshDelay: 0.05
        )

        model.refreshBranch()
        model.refreshBranch()
        model.refreshBranch()

        let expectation = expectation(description: "debounced refresh completes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(runnerCalls.value, 1)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
#endif
