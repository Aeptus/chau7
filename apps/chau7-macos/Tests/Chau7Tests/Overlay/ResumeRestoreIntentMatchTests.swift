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
        XCTAssertFalse(match.directoryMatches,
                       "Empty expected directory must NOT match a non-empty current directory")
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
        XCTAssertTrue(match.directoryMatches,
                      "Both directories empty is a legitimate match — directory-less saved state vs directory-less live session")
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
        XCTAssertNil(match.normalizedExpectedProvider,
                     "Empty expected provider must normalize to nil before comparison")
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
