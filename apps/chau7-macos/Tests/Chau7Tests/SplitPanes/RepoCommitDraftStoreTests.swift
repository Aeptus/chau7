import XCTest
@testable import Chau7

/// Direct tests for the extracted RepoCommitDraftStore. The integration
/// path is covered by RepositoryPaneModelTests through the model; these
/// tests pin the persistence + conventional-prefix surface in isolation,
/// using a scratch UserDefaults suite so they don't bleed into the host
/// app's standard defaults.
final class RepoCommitDraftStoreTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // Suite name unique per run so concurrent test runs don't collide.
        let suiteName = "chau7.repoDraftStore.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        // No persistence file gets created for in-memory suites — nothing
        // to clean up beyond dropping the reference.
        defaults = nil
        super.tearDown()
    }

    // MARK: - Persistence

    func testLoadDraftReturnsEmptyStringWhenNothingSaved() {
        let store = RepoCommitDraftStore(defaults: defaults)
        XCTAssertEqual(store.loadDraft(for: "/repo/path"), "")
    }

    func testSaveAndLoadRoundtrips() {
        let store = RepoCommitDraftStore(defaults: defaults)
        store.saveDraft("feat: in-progress draft", for: "/repo/path")
        XCTAssertEqual(store.loadDraft(for: "/repo/path"), "feat: in-progress draft")
    }

    func testSaveWhitespaceOnlyRemovesPersistedEntry() {
        let store = RepoCommitDraftStore(defaults: defaults)
        store.saveDraft("kept", for: "/repo/path")
        store.saveDraft("   \n  ", for: "/repo/path")
        XCTAssertEqual(
            store.loadDraft(for: "/repo/path"), "",
            "Whitespace-only drafts must clear the persisted entry"
        )
    }

    func testClearDraftRemovesPersistedEntry() {
        let store = RepoCommitDraftStore(defaults: defaults)
        store.saveDraft("about to clear", for: "/repo/path")
        store.clearDraft(for: "/repo/path")
        XCTAssertEqual(store.loadDraft(for: "/repo/path"), "")
    }

    func testPerDirectoryIsolation() {
        let store = RepoCommitDraftStore(defaults: defaults)
        store.saveDraft("alpha", for: "/repo/a")
        store.saveDraft("beta", for: "/repo/b")
        XCTAssertEqual(store.loadDraft(for: "/repo/a"), "alpha")
        XCTAssertEqual(store.loadDraft(for: "/repo/b"), "beta")
        store.clearDraft(for: "/repo/a")
        XCTAssertEqual(store.loadDraft(for: "/repo/a"), "")
        XCTAssertEqual(store.loadDraft(for: "/repo/b"), "beta", "Other directory's draft untouched")
    }

    // MARK: - Conventional prefix

    func testApplyPrefixWhenAbsent() {
        let store = RepoCommitDraftStore(defaults: defaults)
        XCTAssertEqual(store.applyPrefix("feat", to: "do the thing"), "feat: do the thing")
    }

    func testApplyPrefixNoopWhenAlreadyPresent() {
        let store = RepoCommitDraftStore(defaults: defaults)
        XCTAssertEqual(store.applyPrefix("feat", to: "feat: existing"), "feat: existing")
        XCTAssertEqual(store.applyPrefix("feat", to: "feat(scope): scoped"), "feat(scope): scoped")
    }

    func testHasConventionalPrefixMatchesKnownPrefixes() {
        let store = RepoCommitDraftStore(defaults: defaults)
        for prefix in RepoCommitDraftStore.prefixes {
            XCTAssertTrue(
                store.hasConventionalPrefix("\(prefix): body"),
                "\(prefix): should match"
            )
            XCTAssertTrue(
                store.hasConventionalPrefix("\(prefix)(scope): body"),
                "\(prefix)(scope): should match"
            )
        }
    }

    func testHasConventionalPrefixRejectsUnknownPrefix() {
        let store = RepoCommitDraftStore(defaults: defaults)
        XCTAssertFalse(store.hasConventionalPrefix("misc: body"))
        XCTAssertFalse(store.hasConventionalPrefix("plain message"))
    }

    func testHasConventionalPrefixIsCaseInsensitive() {
        let store = RepoCommitDraftStore(defaults: defaults)
        XCTAssertTrue(store.hasConventionalPrefix("Feat: body"))
        XCTAssertTrue(store.hasConventionalPrefix("FIX: body"))
    }
}
