import XCTest
@testable import Chau7

@MainActor
final class WindowModelRegistryTests: XCTestCase {
    private var registry: WindowModelRegistry!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: SavedTabState.userDefaultsKey)
        UserDefaults.standard.removeObject(forKey: SavedMultiWindowState.userDefaultsKey)
        registry = WindowModelRegistry()
    }

    override func tearDown() {
        registry = nil
        UserDefaults.standard.removeObject(forKey: SavedTabState.userDefaultsKey)
        UserDefaults.standard.removeObject(forKey: SavedMultiWindowState.userDefaultsKey)
        super.tearDown()
    }

    private func makeModel() -> OverlayTabsModel {
        OverlayTabsModel(appModel: AppModel(), restoreState: false)
    }

    // MARK: - Registration

    func testRegisterAssignsStableSequentialWindowIDs() {
        let first = makeModel()
        let second = makeModel()

        XCTAssertTrue(registry.register(first))
        XCTAssertTrue(registry.register(second))

        let all = registry.allModels
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[0].windowID, 0)
        XCTAssertTrue(all[0].model === first)
        XCTAssertEqual(all[1].windowID, 1)
        XCTAssertTrue(all[1].model === second)
    }

    func testRegisterSameModelTwiceIsANoOp() {
        let model = makeModel()

        XCTAssertTrue(registry.register(model))
        XCTAssertFalse(registry.register(model))

        XCTAssertEqual(registry.allModels.count, 1)
        XCTAssertEqual(registry.allModels.first?.windowID, 0)
    }

    func testUnregisterRemovesOnlyThatModelAndPreservesOtherIDs() {
        let first = makeModel()
        let second = makeModel()
        registry.register(first)
        registry.register(second)

        registry.unregister(first)

        let all = registry.allModels
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].windowID, 1)
        XCTAssertTrue(all[0].model === second)
    }

    func testWindowIDsNeverReusedAfterUnregister() {
        let first = makeModel()
        let second = makeModel()
        registry.register(first)
        registry.unregister(first)
        registry.register(second)

        XCTAssertEqual(registry.allModels.map(\.windowID), [1])
    }

    func testUnregisterUnknownModelIsANoOp() {
        let registered = makeModel()
        registry.register(registered)

        registry.unregister(makeModel())

        XCTAssertEqual(registry.allModels.count, 1)
        XCTAssertTrue(registry.allModels.first?.model === registered)
    }

    // MARK: - Lookups

    func testAllTabsSpansEveryRegisteredWindow() {
        let first = makeModel()
        let second = makeModel()
        registry.register(first)
        registry.register(second)

        let expected = first.tabs.map(\.id) + second.tabs.map(\.id)
        XCTAssertFalse(expected.isEmpty)
        XCTAssertEqual(registry.allTabs.map(\.id), expected)
    }

    func testModelContainingTabResolvesAcrossWindows() throws {
        let first = makeModel()
        let second = makeModel()
        registry.register(first)
        registry.register(second)

        let tabInSecond = try XCTUnwrap(second.tabs.first?.id)
        XCTAssertTrue(registry.model(containingTab: tabInSecond) === second)
        XCTAssertNil(registry.model(containingTab: UUID()))
    }

    // MARK: - TabDirectoryProviding seam

    /// RemoteControlManager consumes the MCP side exclusively through
    /// `TabDirectoryProviding`, so a plain fake can stand in for
    /// TerminalControlService. RemoteControlManager itself is not constructed
    /// here — touching `.shared` builds the whole remote stack (IPC server,
    /// observers), which unit tests must never do — so this verifies the
    /// protocol surface is fake-able and records what the fake would observe.
    func testFakeTabDirectoryCanStandInForTerminalControlService() {
        final class FakeTabDirectory: TabDirectoryProviding {
            var models: [OverlayTabsModel] = []
            var clearedTabIDs: [UUID] = []
            var resolvedApprovals: [(requestID: String, approved: Bool)] = []

            var allOverlayModels: [OverlayTabsModel] {
                models
            }

            func clearPersistentNotificationStyleAcrossWindows(tabID: UUID) -> Bool {
                clearedTabIDs.append(tabID)
                return true
            }

            func resolveApproval(requestID: String, approved: Bool) {
                resolvedApprovals.append((requestID, approved))
            }
        }

        let fake = FakeTabDirectory()
        let model = makeModel()
        fake.models = [model]

        let directory: TabDirectoryProviding = fake
        XCTAssertTrue(directory.allOverlayModels.first === model)

        let tabID = UUID()
        XCTAssertTrue(directory.clearPersistentNotificationStyleAcrossWindows(tabID: tabID))
        directory.resolveApproval(requestID: "req-1", approved: true)

        XCTAssertEqual(fake.clearedTabIDs, [tabID])
        XCTAssertEqual(fake.resolvedApprovals.count, 1)
        XCTAssertEqual(fake.resolvedApprovals.first?.requestID, "req-1")
        XCTAssertEqual(fake.resolvedApprovals.first?.approved, true)
    }

    /// The production conformance: TerminalControlService's directory view is
    /// backed by its registry, models only, in stable window order.
    func testTerminalControlServiceExposesRegisteredModelsAsDirectory() {
        let model = makeModel()
        TerminalControlService.shared.register(model)
        defer { TerminalControlService.shared.unregister(model) }

        let directory: TabDirectoryProviding = TerminalControlService.shared
        XCTAssertTrue(directory.allOverlayModels.contains(where: { $0 === model }))
        XCTAssertEqual(
            directory.allOverlayModels.map(ObjectIdentifier.init),
            TerminalControlService.shared.allModels.map { ObjectIdentifier($0.model) }
        )
    }
}
