import XCTest
@testable import Chau7

/// SPM-runnable tests for `OverlayTabsModel.evaluateResumeRestoreIntent`.
///
/// The instance method `validateResumeRestoreIntent` (in
/// `OverlayTabsModel+RestorePipeline.swift`) is the gatekeeper that decides
/// whether a queued resume-prefill should be delivered to a live pane. Before
/// T1, the validator was only reachable through a `TerminalSessionModel` and
/// the underlying tests sat behind `#if !SWIFT_PACKAGE`. Extracting the pure
/// normalize+compare logic to a static helper unlocks `swift test` coverage
/// without requiring AppKit/UI scaffolding.
final class ResumeRestoreIntentMatchTests: XCTestCase {

    // MARK: - Directory check

    /// Directory mismatch must reject. The pre-tightening implementation
    /// treated "expected directory empty" as "match anything"; the comment
    /// in the production code calls this out explicitly. Confirm the modern
    /// behaviour rejects empty-expected vs non-empty-current.
    func testDirectoryMismatchRejects() {
        let match = OverlayTabsModel.evaluateResumeRestoreIntent(
            expectedDirectory: "/saved/dir",
            currentDirectory: "/live/dir",
            expectedProvider: "codex",
            currentProvider: "codex",
            expectedSessionID: "abc-123",
            currentSessionID: "abc-123"
        )
        XCTAssertFalse(match.directoryMatches)
        XCTAssertFalse(match.allMatch)
    }

    func testDirectoryEmptyExpectedNonEmptyCurrentRejects() {
        let match = OverlayTabsModel.evaluateResumeRestoreIntent(
            expectedDirectory: "",
            currentDirectory: "/live/dir",
            expectedProvider: "codex",
            currentProvider: "codex",
            expectedSessionID: "abc-123",
            currentSessionID: "abc-123"
        )
        XCTAssertFalse(
            match.directoryMatches,
            "Empty expected directory must NOT match a non-empty current directory"
        )
    }

    func testDirectoryBothEmptyMatches() {
        let match = OverlayTabsModel.evaluateResumeRestoreIntent(
            expectedDirectory: "",
            currentDirectory: "",
            expectedProvider: nil,
            currentProvider: nil,
            expectedSessionID: nil,
            currentSessionID: nil
        )
        XCTAssertTrue(
            match.directoryMatches,
            "Both directories empty is a legitimate match — directory-less saved state vs directory-less live session"
        )
        XCTAssertTrue(match.allMatch)
    }

    func testDirectoryWhitespaceTrimmedBeforeCompare() {
        let match = OverlayTabsModel.evaluateResumeRestoreIntent(
            expectedDirectory: "  /shared/dir  ",
            currentDirectory: "/shared/dir\n",
            expectedProvider: nil,
            currentProvider: nil,
            expectedSessionID: nil,
            currentSessionID: nil
        )
        XCTAssertTrue(match.directoryMatches)
    }

    // MARK: - Provider check

    /// Provider mismatch (e.g. saved as claude, live session is codex) must reject.
    func testProviderMismatchRejects() {
        let match = OverlayTabsModel.evaluateResumeRestoreIntent(
            expectedDirectory: "/shared/dir",
            currentDirectory: "/shared/dir",
            expectedProvider: "claude",
            currentProvider: "codex",
            expectedSessionID: "abc-123",
            currentSessionID: "abc-123"
        )
        XCTAssertFalse(match.providerMatches)
        XCTAssertFalse(match.allMatch)
    }

    /// Nil expected provider is the "any provider acceptable" wildcard —
    /// the saved state didn't record a provider, so we trust the live one.
    func testProviderNilExpectedAcceptsAnyCurrent() {
        let match = OverlayTabsModel.evaluateResumeRestoreIntent(
            expectedDirectory: "/dir",
            currentDirectory: "/dir",
            expectedProvider: nil,
            currentProvider: "codex",
            expectedSessionID: nil,
            currentSessionID: nil
        )
        XCTAssertTrue(match.providerMatches)
        XCTAssertTrue(match.allMatch)
    }

    /// Empty-string expected provider normalizes to nil and behaves as the
    /// wildcard — a regression-fix dimension: AIResumeParser.normalizeProviderName
    /// is what makes the empty-string-to-nil conversion happen.
    func testProviderEmptyStringExpectedActsAsWildcard() {
        let match = OverlayTabsModel.evaluateResumeRestoreIntent(
            expectedDirectory: "/dir",
            currentDirectory: "/dir",
            expectedProvider: "",
            currentProvider: "codex",
            expectedSessionID: nil,
            currentSessionID: nil
        )
        XCTAssertTrue(match.providerMatches)
        XCTAssertNil(
            match.normalizedExpectedProvider,
            "Empty expected provider must normalize to nil before comparison"
        )
    }

    // MARK: - Session ID check

    /// Session-ID mismatch must reject even when directory + provider agree.
    /// Ensures the live pane being reassigned to a different session
    /// doesn't get an old session's resume command.
    func testSessionIDMismatchRejects() {
        let match = OverlayTabsModel.evaluateResumeRestoreIntent(
            expectedDirectory: "/shared/dir",
            currentDirectory: "/shared/dir",
            expectedProvider: "codex",
            currentProvider: "codex",
            expectedSessionID: "saved-abc",
            currentSessionID: "live-xyz"
        )
        XCTAssertFalse(match.sessionMatches)
        XCTAssertFalse(match.allMatch)
    }

    /// Nil expected session ID is the "any session acceptable" wildcard.
    /// Used when the saved state has provider but no specific session ID
    /// (e.g. older saves predate per-session tracking).
    func testSessionIDNilExpectedAcceptsAnyCurrent() {
        let match = OverlayTabsModel.evaluateResumeRestoreIntent(
            expectedDirectory: "/dir",
            currentDirectory: "/dir",
            expectedProvider: "codex",
            currentProvider: "codex",
            expectedSessionID: nil,
            currentSessionID: "any-session"
        )
        XCTAssertTrue(match.sessionMatches)
        XCTAssertTrue(match.allMatch)
    }

    /// Invalid session-id strings (containing shell metacharacters or
    /// otherwise rejected by AIResumeParser.isValidSessionId) normalize to
    /// nil and therefore act as wildcards. This is intentional: better to
    /// fall back to wildcard than to reject a valid resume because the
    /// saved-state session ID was malformed.
    func testSessionIDInvalidExpectedNormalizesToNilWildcard() {
        let match = OverlayTabsModel.evaluateResumeRestoreIntent(
            expectedDirectory: "/dir",
            currentDirectory: "/dir",
            expectedProvider: "codex",
            currentProvider: "codex",
            expectedSessionID: "invalid; rm -rf /",
            currentSessionID: "valid-session"
        )
        XCTAssertNil(match.normalizedExpectedSessionID)
        XCTAssertTrue(match.sessionMatches)
    }

    // MARK: - Composite match

    /// All three dimensions match → accept.
    func testFullMatchAccepts() {
        let match = OverlayTabsModel.evaluateResumeRestoreIntent(
            expectedDirectory: "/shared/dir",
            currentDirectory: "/shared/dir",
            expectedProvider: "codex",
            currentProvider: "codex",
            expectedSessionID: "abc-123",
            currentSessionID: "abc-123"
        )
        XCTAssertTrue(match.allMatch)
    }

    // MARK: - Identity-not-yet-corroborated (regression class)
    //
    // The prefill validator gets called the moment the terminal can accept
    // input — which is often *before* output-derived identity has been
    // corroborated. When `effectiveAIProvider` / `effectiveAISessionId`
    // return nil during that window, a strict `expected == current` check
    // rejects the prefill on the first delivery attempt and never retries.
    // The launch arguments (`claude --resume <id>` / `codex resume <id>`)
    // guarantee the session is correct by construction, so unknown-current
    // is treated as match. Without this, *every* time identity detection
    // tightens (e.g. b39a863a corroboration requirement, d485275c codex-
    // cwd plumbing), prefill delivery silently regresses.

    func testProviderUnknownCurrentTreatedAsMatch() {
        let match = OverlayTabsModel.evaluateResumeRestoreIntent(
            expectedDirectory: "/shared/dir",
            currentDirectory: "/shared/dir",
            expectedProvider: "codex",
            currentProvider: nil,
            expectedSessionID: "abc-123",
            currentSessionID: "abc-123"
        )
        XCTAssertTrue(
            match.providerMatches,
            "Unknown current provider must NOT reject — identity detection catches up after launch"
        )
        XCTAssertTrue(match.allMatch)
    }

    func testSessionIDUnknownCurrentTreatedAsMatch() {
        let match = OverlayTabsModel.evaluateResumeRestoreIntent(
            expectedDirectory: "/shared/dir",
            currentDirectory: "/shared/dir",
            expectedProvider: "codex",
            currentProvider: "codex",
            expectedSessionID: "abc-123",
            currentSessionID: nil
        )
        XCTAssertTrue(
            match.sessionMatches,
            "Unknown current session ID must NOT reject — output corroboration runs after the first prompt"
        )
        XCTAssertTrue(match.allMatch)
    }

    func testBothProviderAndSessionUnknownStillMatchesWhenDirectoryAgrees() {
        let match = OverlayTabsModel.evaluateResumeRestoreIntent(
            expectedDirectory: "/shared/dir",
            currentDirectory: "/shared/dir",
            expectedProvider: "claude",
            currentProvider: nil,
            expectedSessionID: "sess-1",
            currentSessionID: nil
        )
        XCTAssertTrue(match.providerMatches)
        XCTAssertTrue(match.sessionMatches)
        XCTAssertTrue(
            match.allMatch,
            "Pre-corroboration window must not reject — this is the resume-prefill regression class"
        )
    }

    /// Lenient-on-unknown must NOT extend to confirmed mismatch — if current
    /// identity is non-nil and disagrees with expected, that's a real
    /// cross-session contamination risk and must still reject.
    func testConfirmedProviderMismatchStillRejects() {
        let match = OverlayTabsModel.evaluateResumeRestoreIntent(
            expectedDirectory: "/dir",
            currentDirectory: "/dir",
            expectedProvider: "codex",
            currentProvider: "claude",
            expectedSessionID: nil,
            currentSessionID: nil
        )
        XCTAssertFalse(match.providerMatches)
        XCTAssertFalse(match.allMatch)
    }

    func testConfirmedSessionIDMismatchStillRejects() {
        let match = OverlayTabsModel.evaluateResumeRestoreIntent(
            expectedDirectory: "/dir",
            currentDirectory: "/dir",
            expectedProvider: "codex",
            currentProvider: "codex",
            expectedSessionID: "saved-abc",
            currentSessionID: "live-xyz"
        )
        XCTAssertFalse(match.sessionMatches)
        XCTAssertFalse(match.allMatch)
    }

    // MARK: - Directory canonicalization (regression class)
    //
    // Raw string compare on directories rejects path forms that are
    // identical on disk: macOS /var ↔ /private/var, trailing slashes,
    // unresolved .. segments. canonicalizeRestoreDirectory normalizes
    // both sides via URL.resolvingSymlinksInPath before comparing.

    func testDirectoryTrailingSlashCanonicalizesToMatch() {
        let match = OverlayTabsModel.evaluateResumeRestoreIntent(
            expectedDirectory: "/Users/me/proj/",
            currentDirectory: "/Users/me/proj",
            expectedProvider: nil,
            currentProvider: nil,
            expectedSessionID: nil,
            currentSessionID: nil
        )
        XCTAssertTrue(
            match.directoryMatches,
            "Trailing slash must not block match — both forms canonicalize to the same path"
        )
    }

    func testDirectoryDotDotCanonicalizesToMatch() {
        let match = OverlayTabsModel.evaluateResumeRestoreIntent(
            expectedDirectory: "/Users/me/proj/sub/..",
            currentDirectory: "/Users/me/proj",
            expectedProvider: nil,
            currentProvider: nil,
            expectedSessionID: nil,
            currentSessionID: nil
        )
        XCTAssertTrue(
            match.directoryMatches,
            ".. segments must resolve before comparison"
        )
    }

    /// macOS-specific: `/var` is a symlink to `/private/var`. When one side
    /// captured the pre-resolve form (e.g. from saved state generated by an
    /// older code path) and the other side captured the post-resolve form
    /// (from OSC-7 reporting), strict-equality compare fails. Canonicalize
    /// resolves both to /private/var.
    func testDirectoryPrivateVarSymlinkCanonicalizesToMatch() {
        // Skip in environments where the symlink doesn't exist (Linux CI).
        guard FileManager.default.fileExists(atPath: "/private/var") else {
            return
        }
        let match = OverlayTabsModel.evaluateResumeRestoreIntent(
            expectedDirectory: "/var/folders",
            currentDirectory: "/private/var/folders",
            expectedProvider: nil,
            currentProvider: nil,
            expectedSessionID: nil,
            currentSessionID: nil
        )
        XCTAssertTrue(
            match.directoryMatches,
            "/var ↔ /private/var must canonicalize to the same path on macOS"
        )
    }

    // MARK: - canonicalizeRestoreDirectory (direct unit tests)
    //
    // Direct tests of the canonicalization helper. The bigger
    // evaluateResumeRestoreIntent tests cover the directory dimension
    // end-to-end, but the helper is the load-bearing piece and merits
    // unit-level coverage so any regression to its semantics fails
    // independently of evaluate's other plumbing.

    func testCanonicalizeEmptyReturnsEmpty() {
        XCTAssertEqual(
            OverlayTabsModel.canonicalizeRestoreDirectory(""),
            "",
            "Empty in must stay empty — guards against URL('').resolvingSymlinksInPath becoming '/'"
        )
    }

    func testCanonicalizeWhitespaceOnlyReturnsEmpty() {
        XCTAssertEqual(OverlayTabsModel.canonicalizeRestoreDirectory("   \n\t"), "")
    }

    func testCanonicalizeAbsolutePathStripsTrailingSlash() {
        XCTAssertEqual(
            OverlayTabsModel.canonicalizeRestoreDirectory("/Users/me/proj/"),
            "/Users/me/proj"
        )
    }

    func testCanonicalizeAbsolutePathResolvesDotDot() {
        XCTAssertEqual(
            OverlayTabsModel.canonicalizeRestoreDirectory("/Users/me/proj/sub/.."),
            "/Users/me/proj"
        )
    }

    func testCanonicalizeAbsolutePathCollapsesDoubleSlashes() {
        XCTAssertEqual(
            OverlayTabsModel.canonicalizeRestoreDirectory("/Users//me///proj"),
            "/Users/me/proj"
        )
    }

    func testCanonicalizeRootStaysRoot() {
        XCTAssertEqual(OverlayTabsModel.canonicalizeRestoreDirectory("/"), "/")
    }

    func testCanonicalizeTildePathExpandsToHome() {
        let canon = OverlayTabsModel.canonicalizeRestoreDirectory("~/proj")
        let homeProj = NSString(string: "~/proj").expandingTildeInPath
        let expectedCanon = URL(fileURLWithPath: homeProj).resolvingSymlinksInPath().path
        XCTAssertEqual(canon, expectedCanon)
        XCTAssertFalse(
            canon.hasPrefix("~"),
            "Tilde must be expanded — saved states may carry ~/proj from script-driven setups"
        )
    }

    /// Relative paths must NOT be implicitly expanded against the Chau7
    /// app's current working directory — that would silently match the
    /// wrong directory. Return as-is so the comparison fails cleanly.
    func testCanonicalizeRelativePathLeftUntouched() {
        XCTAssertEqual(
            OverlayTabsModel.canonicalizeRestoreDirectory("proj/sub"),
            "proj/sub",
            "Relative paths must not be expanded against the process cwd"
        )
    }

    /// Idempotence: running canonicalization twice produces the same
    /// result as once. Guards against future regressions where someone
    /// adds a step that requires an absolute-already form.
    func testCanonicalizationIsIdempotent() {
        let inputs = [
            "/Users/me/proj/",
            "/Users/me/proj/sub/..",
            "/var/folders",
            "~/proj",
            "",
            "rel/path",
        ]
        for input in inputs {
            let once = OverlayTabsModel.canonicalizeRestoreDirectory(input)
            let twice = OverlayTabsModel.canonicalizeRestoreDirectory(once)
            XCTAssertEqual(
                once,
                twice,
                "canonicalize is not idempotent for \(input.debugDescription) — once=\(once.debugDescription) twice=\(twice.debugDescription)"
            )
        }
    }

    // MARK: - Truth table (exhaustive)
    //
    // The validator is "match if (dir match) AND (provider match) AND (sess
    // match)" where each dimension is one of {match, mismatch, unknown}.
    // That's 27 combinations of the matrix-relevant inputs. Most are
    // implicitly covered by other tests but this exhaustive sweep locks
    // the truth table down — any future tightening that flips a cell's
    // expected outcome must update the explicit assertion below, which a
    // code review will surface.

    func testTruthTableExhaustive() {
        struct Case {
            let label: String
            let expectedDir: String
            let currentDir: String
            let expectedProvider: String?
            let currentProvider: String?
            let expectedSession: String?
            let currentSession: String?
            let shouldMatch: Bool
        }

        let cases: [Case] = [
            // Everything aligned →
            .init(label: "all-match",
                  expectedDir: "/d", currentDir: "/d",
                  expectedProvider: "codex", currentProvider: "codex",
                  expectedSession: "s1", currentSession: "s1",
                  shouldMatch: true),
            // Each single dimension mismatched →
            .init(label: "dir-mismatch",
                  expectedDir: "/d", currentDir: "/e",
                  expectedProvider: "codex", currentProvider: "codex",
                  expectedSession: "s1", currentSession: "s1",
                  shouldMatch: false),
            .init(label: "provider-mismatch",
                  expectedDir: "/d", currentDir: "/d",
                  expectedProvider: "codex", currentProvider: "claude",
                  expectedSession: "s1", currentSession: "s1",
                  shouldMatch: false),
            .init(label: "session-mismatch",
                  expectedDir: "/d", currentDir: "/d",
                  expectedProvider: "codex", currentProvider: "codex",
                  expectedSession: "s1", currentSession: "s2",
                  shouldMatch: false),
            // Each single dimension unknown (current=nil) → match
            .init(label: "provider-unknown-current",
                  expectedDir: "/d", currentDir: "/d",
                  expectedProvider: "codex", currentProvider: nil,
                  expectedSession: "s1", currentSession: "s1",
                  shouldMatch: true),
            .init(label: "session-unknown-current",
                  expectedDir: "/d", currentDir: "/d",
                  expectedProvider: "codex", currentProvider: "codex",
                  expectedSession: "s1", currentSession: nil,
                  shouldMatch: true),
            // Both identity dimensions unknown current — still match if dir agrees
            .init(label: "both-identity-unknown",
                  expectedDir: "/d", currentDir: "/d",
                  expectedProvider: "codex", currentProvider: nil,
                  expectedSession: "s1", currentSession: nil,
                  shouldMatch: true),
            // Unknown current cannot rescue a dir mismatch
            .init(label: "unknown-identity-cannot-rescue-dir-mismatch",
                  expectedDir: "/d", currentDir: "/e",
                  expectedProvider: "codex", currentProvider: nil,
                  expectedSession: "s1", currentSession: nil,
                  shouldMatch: false),
            // Each single dimension expected=nil (wildcard) → match
            .init(label: "provider-expected-nil",
                  expectedDir: "/d", currentDir: "/d",
                  expectedProvider: nil, currentProvider: "codex",
                  expectedSession: "s1", currentSession: "s1",
                  shouldMatch: true),
            .init(label: "session-expected-nil",
                  expectedDir: "/d", currentDir: "/d",
                  expectedProvider: "codex", currentProvider: "codex",
                  expectedSession: nil, currentSession: "anything",
                  shouldMatch: true),
            // Edge: expected dir empty + current dir non-empty → reject (tightened by d485275c)
            .init(label: "empty-expected-dir-rejects",
                  expectedDir: "", currentDir: "/d",
                  expectedProvider: "codex", currentProvider: "codex",
                  expectedSession: "s1", currentSession: "s1",
                  shouldMatch: false),
            // Edge: both dirs empty → match (legitimate directory-less state)
            .init(label: "both-dirs-empty",
                  expectedDir: "", currentDir: "",
                  expectedProvider: nil, currentProvider: nil,
                  expectedSession: nil, currentSession: nil,
                  shouldMatch: true),
            // Path canonicalization
            .init(label: "trailing-slash-canonicalizes",
                  expectedDir: "/d/", currentDir: "/d",
                  expectedProvider: nil, currentProvider: nil,
                  expectedSession: nil, currentSession: nil,
                  shouldMatch: true),
        ]

        for c in cases {
            let match = OverlayTabsModel.evaluateResumeRestoreIntent(
                expectedDirectory: c.expectedDir,
                currentDirectory: c.currentDir,
                expectedProvider: c.expectedProvider,
                currentProvider: c.currentProvider,
                expectedSessionID: c.expectedSession,
                currentSessionID: c.currentSession
            )
            XCTAssertEqual(
                match.allMatch,
                c.shouldMatch,
                "Truth-table case '\(c.label)' expected allMatch=\(c.shouldMatch) but got \(match.allMatch) — directoryMatches=\(match.directoryMatches) providerMatches=\(match.providerMatches) sessionMatches=\(match.sessionMatches)"
            )
        }
    }

    // MARK: - Composite match

    /// `allMatch` is the AND of the three dimensions — confirm a single
    /// failure in any dimension flips it false.
    func testAllMatchRequiresAllThreeDimensions() {
        let dirOnlyFails = OverlayTabsModel.evaluateResumeRestoreIntent(
            expectedDirectory: "/saved",
            currentDirectory: "/live",
            expectedProvider: "codex",
            currentProvider: "codex",
            expectedSessionID: "abc",
            currentSessionID: "abc"
        )
        XCTAssertFalse(dirOnlyFails.allMatch)
        XCTAssertTrue(dirOnlyFails.providerMatches)
        XCTAssertTrue(dirOnlyFails.sessionMatches)

        let providerOnlyFails = OverlayTabsModel.evaluateResumeRestoreIntent(
            expectedDirectory: "/dir",
            currentDirectory: "/dir",
            expectedProvider: "claude",
            currentProvider: "codex",
            expectedSessionID: "abc",
            currentSessionID: "abc"
        )
        XCTAssertFalse(providerOnlyFails.allMatch)
        XCTAssertTrue(providerOnlyFails.directoryMatches)
        XCTAssertTrue(providerOnlyFails.sessionMatches)

        let sessionOnlyFails = OverlayTabsModel.evaluateResumeRestoreIntent(
            expectedDirectory: "/dir",
            currentDirectory: "/dir",
            expectedProvider: "codex",
            currentProvider: "codex",
            expectedSessionID: "saved",
            currentSessionID: "live"
        )
        XCTAssertFalse(sessionOnlyFails.allMatch)
        XCTAssertTrue(sessionOnlyFails.directoryMatches)
        XCTAssertTrue(sessionOnlyFails.providerMatches)
    }
}
