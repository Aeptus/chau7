import AppKit
import XCTest
@testable import Chau7

@MainActor
final class SessionIdentityDiscoveryTests: XCTestCase {
    private var savedFinder: ((String, Date?, Set<String>) -> String?)?
    private var savedBackgroundFinder: (@Sendable (String, Date?, Set<String>) -> String?)?

    private func restoreFinder() {
        OverlayTabsModel.registerSessionFinder(
            forProviderKey: "codex",
            finder: savedFinder ?? { _, _, _ in nil },
            backgroundFinder: savedBackgroundFinder
        )
    }

    private func makeSession() -> TerminalSessionModel {
        let session = TerminalSessionModel(appModel: AppModel())
        savedFinder = OverlayTabsModel.sessionFinders["codex"]
        savedBackgroundFinder = OverlayTabsModel.backgroundSessionFinders["codex"]
        session.currentDirectory = "/tmp/discovery-original"
        session.lastAIProvider = "codex"
        session.agentStartedAt = Date()
        return session
    }

    private func waitForDiscovery(_ session: TerminalSessionModel) async {
        for _ in 0 ..< 500 {
            if !session.observedSessionLookupInFlight { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("background discovery did not complete")
    }

    func testStatusReadsRemainResponsiveWhileFileDiscoveryIsBlockedAndCoalesce() async {
        let session = makeSession()
        defer { restoreFinder() }
        let started = expectation(description: "background discovery started")
        started.assertForOverFulfill = true
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        OverlayTabsModel.registerSessionFinder(
            forProviderKey: "codex",
            finder: { _, _, _ in XCTFail("status getter invoked synchronous finder")
                return nil
            },
            backgroundFinder: { _, _, _ in
                XCTAssertFalse(Thread.isMainThread)
                started.fulfill()
                _ = gate.wait(timeout: .now() + 5)
                return "observed-session"
            }
        )
        let synthetic = session.effectiveAISessionId
        await fulfillment(of: [started], timeout: 5)
        for _ in 0 ..< 100 {
            XCTAssertEqual(session.effectiveAISessionId, synthetic)
            _ = session.effectiveStatus
        }
        XCTAssertEqual(session.lastAISessionIdentitySource, .synthetic)
        gate.signal()
        await waitForDiscovery(session)
        XCTAssertEqual(session.effectiveAISessionId, "observed-session")
        XCTAssertEqual(session.lastAISessionIdentitySource, .observed)
    }

    func testFileDiscoveryCannotOverwriteAnExplicitIdentityReceivedWhileScanning() async {
        let session = makeSession()
        defer { restoreFinder() }
        let started = expectation(description: "discovery started")
        let finished = expectation(description: "discovery returned")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        OverlayTabsModel.registerSessionFinder(
            forProviderKey: "codex", finder: { _, _, _ in nil },
            backgroundFinder: { _, _, _ in
                started.fulfill()
                _ = gate.wait(timeout: .now() + 5)
                finished.fulfill()
                return "old-session"
            }
        )
        _ = session.effectiveAISessionId
        await fulfillment(of: [started], timeout: 5)
        session.lastAISessionId = "explicit-session"
        session.lastAISessionIdentitySource = .explicit
        gate.signal()
        await fulfillment(of: [finished], timeout: 5)
        await waitForDiscovery(session)
        XCTAssertEqual(session.effectiveAISessionId, "explicit-session")
        XCTAssertEqual(session.lastAISessionIdentitySource, .explicit)
    }

    func testDiscoveryForOldDirectoryCannotBeAdoptedAfterDirectoryChange() async {
        let session = makeSession()
        defer { restoreFinder() }
        let started = expectation(description: "discovery started")
        let finished = expectation(description: "discovery returned")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        OverlayTabsModel.registerSessionFinder(
            forProviderKey: "codex", finder: { _, _, _ in nil },
            backgroundFinder: { _, _, _ in
                started.fulfill()
                _ = gate.wait(timeout: .now() + 5)
                finished.fulfill()
                return "old-session"
            }
        )
        let original = session.effectiveAISessionId
        await fulfillment(of: [started], timeout: 5)
        session.currentDirectory = "/tmp/discovery-new"
        gate.signal()
        await fulfillment(of: [finished], timeout: 5)
        await waitForDiscovery(session)
        XCTAssertEqual(session.lastAISessionId, original)
        XCTAssertEqual(session.lastAISessionIdentitySource, .synthetic)
    }

    func testDiscoveryForRestartedAgentCannotBeAdopted() async throws {
        let session = makeSession()
        defer { restoreFinder() }
        let started = expectation(description: "discovery started")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        OverlayTabsModel.registerSessionFinder(
            forProviderKey: "codex", finder: { _, _, _ in nil },
            backgroundFinder: { _, _, _ in
                started.fulfill()
                _ = gate.wait(timeout: .now() + 5)
                return "old-session"
            }
        )
        _ = session.effectiveAISessionId
        await fulfillment(of: [started], timeout: 5)
        session.agentStartedAt = try XCTUnwrap(session.agentStartedAt).addingTimeInterval(1)
        session.lastAISessionId = nil
        session.lastAISessionIdentitySource = nil
        gate.signal()
        await waitForDiscovery(session)
        XCTAssertNil(session.lastAISessionId)
        XCTAssertNil(session.lastAISessionIdentitySource)
    }

}
