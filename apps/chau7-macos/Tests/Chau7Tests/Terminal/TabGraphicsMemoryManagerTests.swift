import XCTest
@testable import Chau7

@MainActor
final class TabGraphicsMemoryManagerTests: XCTestCase {
    private final class SnapshotReleaser: TabSnapshotReleaser {
        var releases: [(UUID, TabGraphicsMemoryManager.ReleaseTier)] = []

        func releaseSnapshots(forTabID tabID: UUID, tier: TabGraphicsMemoryManager.ReleaseTier) {
            releases.append((tabID, tier))
        }
    }

    private func drainMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    func testPassiveVisiblePhaseKeepsCachedSnapshotsOnly() {
        let manager = TabGraphicsMemoryManager.shared
        let tabID = UUID()
        let releaser = SnapshotReleaser()
        manager.addSnapshotReleaser(releaser)
        defer { manager.removeSnapshotReleaser(releaser) }

        manager.handlePhaseTransition(tabID: tabID, from: .active, to: .passiveVisible)
        drainMainQueue()

        XCTAssertEqual(releaser.releases.count, 1)
        XCTAssertEqual(releaser.releases[0].0, tabID)
        XCTAssertEqual(releaser.releases[0].1, .keepCachedOnly)
    }

    func testWarmPhaseReleasesAllSnapshots() {
        let manager = TabGraphicsMemoryManager.shared
        let tabID = UUID()
        let releaser = SnapshotReleaser()
        manager.addSnapshotReleaser(releaser)
        defer { manager.removeSnapshotReleaser(releaser) }

        manager.handlePhaseTransition(tabID: tabID, from: .passiveVisible, to: .warm)
        drainMainQueue()

        XCTAssertEqual(releaser.releases.count, 1)
        XCTAssertEqual(releaser.releases[0].1, .releaseAll)
    }

    func testActivePromotionReleasesNothing() {
        let manager = TabGraphicsMemoryManager.shared
        let releaser = SnapshotReleaser()
        manager.addSnapshotReleaser(releaser)
        defer { manager.removeSnapshotReleaser(releaser) }

        manager.handlePhaseTransition(tabID: UUID(), from: .warm, to: .active)
        drainMainQueue()

        XCTAssertTrue(releaser.releases.isEmpty)
    }
}
