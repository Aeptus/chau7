import XCTest
@testable import Chau7

/// Pins the uniqueness invariant of the persisted identity list: corrupt or
/// merged persisted data with duplicate rootPaths must be deduplicated on
/// load, never crash a rootPath-keyed dictionary build downstream.
final class KnownRepoIdentityStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "KnownRepoIdentityStoreTests"
    private let identitiesKey = "repository.knownRepoIdentities.v1"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func persist(_ identities: [KnownRepoIdentity]) throws {
        let data = try JSONEncoder().encode(identities)
        defaults.set(data, forKey: identitiesKey)
    }

    func testLoadDeduplicatesDuplicateRootPaths() throws {
        let newer = KnownRepoIdentity(rootPath: "/repo/a", lastConfirmedAt: Date(), lastKnownBranch: "main")
        let older = KnownRepoIdentity(rootPath: "/repo/a", lastConfirmedAt: .distantPast, lastKnownBranch: "stale")
        let other = KnownRepoIdentity(rootPath: "/repo/b", lastConfirmedAt: .distantPast, lastKnownBranch: nil)
        try persist([newer, older, other])

        let store = KnownRepoIdentityStore(defaults: defaults, bootstrapRoots: [])
        let roots = store.allRoots()

        XCTAssertEqual(roots.sorted(), ["/repo/a", "/repo/b"])
        XCTAssertEqual(store.allIdentities().count, 2)
    }

    func testMergeRecentRootsSurvivesDuplicateIdentities() throws {
        // Even if duplicates somehow re-enter the in-memory list, the
        // rootPath-keyed merge must not trap.
        let dup1 = KnownRepoIdentity(rootPath: "/repo/a", lastConfirmedAt: Date(), lastKnownBranch: "main")
        let dup2 = KnownRepoIdentity(rootPath: "/repo/a", lastConfirmedAt: .distantPast, lastKnownBranch: nil)
        try persist([dup1, dup2])

        let store = KnownRepoIdentityStore(defaults: defaults, bootstrapRoots: [])
        store.mergeRecentRoots(["/repo/a", "/repo/c"])

        let roots = store.allRoots()
        XCTAssertTrue(roots.contains("/repo/a"))
        XCTAssertTrue(roots.contains("/repo/c"))
        XCTAssertEqual(roots.filter { $0 == "/repo/a" }.count, 1)
    }

    func testLoadCapsIdentitiesAtMaximum() throws {
        let many = (0 ..< 80).map {
            KnownRepoIdentity(rootPath: "/repo/\($0)", lastConfirmedAt: .distantPast, lastKnownBranch: nil)
        }
        try persist(many)

        let store = KnownRepoIdentityStore(defaults: defaults, bootstrapRoots: [])
        XCTAssertEqual(store.allIdentities().count, 50)
    }
}
