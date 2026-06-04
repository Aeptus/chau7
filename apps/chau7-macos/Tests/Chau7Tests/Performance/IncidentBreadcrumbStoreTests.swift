import XCTest
@testable import Chau7

final class IncidentBreadcrumbStoreTests: XCTestCase {
    func testProxyRequestLengthParserExtractsReqLen() {
        let message = "anthropic /v1/messages: no tokens extracted (reqLen=1534980, respLen=791)"

        XCTAssertEqual(IncidentBreadcrumbStore.requestLength(fromProxyLogMessage: message), 1_534_980)
    }

    func testProxyRequestLengthParserIgnoresMissingValue() {
        XCTAssertNil(IncidentBreadcrumbStore.requestLength(fromProxyLogMessage: "anthropic /v1/messages"))
        XCTAssertNil(IncidentBreadcrumbStore.requestLength(fromProxyLogMessage: "reqLen=, respLen=12"))
    }

    func testLargeRestorePayloadIsRecordedAndRepeatedSmallDeltaIsSuppressed() {
        let store = makeStore()
        let first = RestorePayloadBreadcrumbSnapshot(
            reason: "autosave",
            windowCount: 2,
            tabCount: 40,
            paneCount: 44,
            legacyPayloadBytes: 700_000,
            multiWindowPayloadBytes: 600_000,
            largestTabPayloadBytes: 300_000,
            largestTabID: "tab-a",
            largestTabTitle: "Optimization",
            largestPanePayloadBytes: 240_000,
            largestPaneID: "pane-a",
            largestPaneDirectory: "/Users/test/Optimization"
        )
        let repeated = RestorePayloadBreadcrumbSnapshot(
            reason: "autosave",
            windowCount: 2,
            tabCount: 40,
            paneCount: 44,
            legacyPayloadBytes: 710_000,
            multiWindowPayloadBytes: 605_000,
            largestTabPayloadBytes: 300_000,
            largestTabID: "tab-a",
            largestTabTitle: "Optimization",
            largestPanePayloadBytes: 240_000,
            largestPaneID: "pane-a",
            largestPaneDirectory: "/Users/test/Optimization"
        )

        store.recordRestorePayloadSnapshot(first)
        store.recordRestorePayloadSnapshot(repeated)

        let breadcrumbs = store.recentBreadcrumbs()
        XCTAssertEqual(breadcrumbs.count, 1)
        XCTAssertEqual(breadcrumbs[0].kind, .restorePayload)
        XCTAssertEqual(breadcrumbs[0].metadata["totalUserDefaultsBytes"], "1300000")
        XCTAssertEqual(breadcrumbs[0].metadata["largestPanePayloadBytes"], "240000")
        XCTAssertEqual(breadcrumbs[0].metadata["largestPaneID"], "pane-a")
    }

    func testRestorePayloadRecordsMaterialByteGrowth() {
        let store = makeStore()

        store.recordRestorePayloadSnapshot(snapshot(totalBytes: 1_100_000))
        store.recordRestorePayloadSnapshot(snapshot(totalBytes: 1_500_000))

        let breadcrumbs = store.recentBreadcrumbs()
        XCTAssertEqual(breadcrumbs.count, 2)
        XCTAssertEqual(breadcrumbs.map(\.kind), [.restorePayload, .restorePayload])
    }

    func testMemoryPressureBreadcrumbIncludesLatestRestoreAndProxyContext() {
        let store = makeStore()
        store.recordRestorePayloadSnapshot(snapshot(totalBytes: 1_300_000))
        store.recordProxyOutputIfHighWater("anthropic /v1/messages: no tokens extracted (reqLen=1534980, respLen=791)")

        store.recordMemoryPressure(
            level: .critical,
            residentBytes: 512 * 1024 * 1024,
            physicalBytes: 8 * 1024 * 1024 * 1024,
            synchronously: true
        )

        let pressure = store.recentBreadcrumbs().last
        XCTAssertEqual(pressure?.kind, .memoryPressure)
        XCTAssertEqual(pressure?.severity, .critical)
        XCTAssertEqual(pressure?.metadata["residentMB"], "512")
        XCTAssertEqual(pressure?.metadata["restore.totalUserDefaultsBytes"], "1300000")
        XCTAssertEqual(pressure?.metadata["proxyRequestHighWaterBytes"], "1534980")
    }

    func testMemoryPressureBreadcrumbSuppressesRepeatedSmallSamples() {
        let store = makeStore()

        store.recordMemoryPressure(
            level: .warning,
            residentBytes: 512 * 1024 * 1024,
            physicalBytes: 8 * 1024 * 1024 * 1024,
            synchronously: true
        )
        store.recordMemoryPressure(
            level: .warning,
            residentBytes: 513 * 1024 * 1024,
            physicalBytes: 8 * 1024 * 1024 * 1024,
            synchronously: true
        )

        let breadcrumbs = store.recentBreadcrumbs()
        XCTAssertEqual(breadcrumbs.count, 1)
        XCTAssertEqual(breadcrumbs[0].metadata["residentMB"], "512")
    }

    func testPanePayloadEstimatorIncludesResumeDirectory() {
        let pane = SavedTerminalPaneState(
            paneID: "pane-a",
            directory: "/shell",
            scrollbackContent: "output",
            aiResumeCommand: "claude --resume session-a",
            aiResumeDirectory: "/session",
            aiProvider: "claude",
            aiSessionId: "session-a",
            knownRepoRoot: "/repo",
            knownGitBranch: "main",
            agentLaunchCommand: "claude"
        )

        let expected = [
            "pane-a",
            "/shell",
            "output",
            "claude --resume session-a",
            "/session",
            "claude",
            "session-a",
            "/repo",
            "main",
            "claude"
        ].reduce(0) { $0 + $1.utf8.count }
        XCTAssertEqual(OverlayTabsModel.estimatedRestorePayloadBytes(for: pane), expected)
    }

    private func snapshot(totalBytes: Int) -> RestorePayloadBreadcrumbSnapshot {
        RestorePayloadBreadcrumbSnapshot(
            reason: "autosave",
            windowCount: 1,
            tabCount: 12,
            paneCount: 12,
            legacyPayloadBytes: totalBytes,
            multiWindowPayloadBytes: 0,
            largestTabPayloadBytes: totalBytes / 2,
            largestTabID: "tab-a",
            largestTabTitle: "Mockup",
            largestPanePayloadBytes: totalBytes / 3,
            largestPaneID: "pane-a",
            largestPaneDirectory: "/Users/test/Mockup"
        )
    }

    private func makeStore() -> IncidentBreadcrumbStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chau7-incident-test-\(UUID().uuidString)", isDirectory: true)
        let suiteName = "chau7.incident.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suiteName)
        }

        return IncidentBreadcrumbStore(
            defaults: defaults,
            directoryProvider: { directory },
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            makeID: { UUID(uuidString: "00000000-0000-0000-0000-000000000001")! }
        )
    }
}
