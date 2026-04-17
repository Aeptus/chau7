import XCTest

#if !SWIFT_PACKAGE
@testable import Chau7

@MainActor
final class TabGraphicsMemoryManagerTests: XCTestCase {
    private final class SnapshotReleaser: TabSnapshotReleaser {
        var releases: [(UUID, TabGraphicsMemoryManager.ReleaseTier)] = []

        func releaseSnapshots(forTabID tabID: UUID, tier: TabGraphicsMemoryManager.ReleaseTier) {
            releases.append((tabID, tier))
        }
    }

    private final class MetalVolatility: TabMetalVolatility {
        var volatilityChanges: [Bool] = []

        func setTexturesVolatile(_ volatile: Bool) {
            volatilityChanges.append(volatile)
        }
    }

    private func drainMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    func testPassiveVisiblePhaseKeepsCachedSnapshotsOnly() {
        let manager = TabGraphicsMemoryManager.shared
        let tabID = UUID()
        let releaser = SnapshotReleaser()
        let metal = MetalVolatility()
        manager.addSnapshotReleaser(releaser)
        manager.register(metalVolatility: metal, forTabID: tabID)
        defer {
            manager.removeSnapshotReleaser(releaser)
            manager.unregister(forTabID: tabID)
        }

        manager.handlePhaseTransition(tabID: tabID, from: .active, to: .passiveVisible)
        drainMainQueue()

        XCTAssertEqual(releaser.releases.count, 1)
        XCTAssertEqual(releaser.releases[0].0, tabID)
        XCTAssertEqual(releaser.releases[0].1, .keepCachedOnly)
        XCTAssertTrue(metal.volatilityChanges.isEmpty)
    }

    func testWarmPhaseReleasesAllSnapshotsAndMarksMetalVolatile() {
        let manager = TabGraphicsMemoryManager.shared
        let tabID = UUID()
        let releaser = SnapshotReleaser()
        let metal = MetalVolatility()
        manager.addSnapshotReleaser(releaser)
        manager.register(metalVolatility: metal, forTabID: tabID)
        defer {
            manager.removeSnapshotReleaser(releaser)
            manager.unregister(forTabID: tabID)
        }

        manager.handlePhaseTransition(tabID: tabID, from: .passiveVisible, to: .warm)
        drainMainQueue()

        XCTAssertEqual(releaser.releases.count, 1)
        XCTAssertEqual(releaser.releases[0].1, .releaseAll)
        XCTAssertEqual(metal.volatilityChanges, [true])
    }
}
#endif
