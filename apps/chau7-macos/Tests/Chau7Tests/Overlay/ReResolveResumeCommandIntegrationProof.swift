#if canImport(AppKit)
import XCTest
import Chau7Core
@testable import Chau7

/// **NOT a regression test — a diagnostic.** Runs the production
/// `reResolveResumeCommand` against the real saved state of the tabs
/// the user has been complaining about, against the real Codex / Claude
/// transcripts on the developer's home directory.
///
/// Updated for the tightened contract: re-resolution now refuses to
/// fabricate identity from cwd alone. A pane that landed with no
/// provider, no session id, AND no command intentionally restores
/// blank — the alternative (newest transcript in cwd wins) created
/// the /Mockup duplication bug. Recovery only works when at least the
/// provider tag survived.
///
/// Gated on a env var so CI never runs it — it's a once-per-investigation
/// gun we point at a specific machine. Set
/// `CHAU7_RUN_RESUME_PROOF=1` to enable.
final class ReResolveResumeCommandIntegrationProof: XCTestCase {

    /// All-nil identity case: the tightened contract returns nil. Asserting
    /// that explicitly documents the deliberate behavior change.
    func testAllNilIdentityRefusesToGuessForEAE7B456() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CHAU7_RUN_RESUME_PROOF"] == "1",
            "Diagnostic test — set CHAU7_RUN_RESUME_PROOF=1 to enable"
        )

        let pane = SavedTerminalPaneState(
            paneID: "599EEB9D-7426-43D3-BD3C-CB8D34791444",
            directory: "/Users/christophehenner/Downloads/Repositories/github-telegram-bot",
            scrollbackContent: nil,
            aiResumeCommand: nil,
            aiResumeDirectory: nil,
            aiProvider: nil,
            aiSessionId: nil,
            aiSessionIdSource: nil,
            // Apple-epoch 803136107 = 2026-06-14T13:21:47Z
            lastOutputAt: Date(timeIntervalSinceReferenceDate: 803_136_107),
            lastInputAt: Date(timeIntervalSinceReferenceDate: 803_136_107)
        )

        XCTAssertNil(
            OverlayTabsModel.reResolveResumeCommand(paneState: pane),
            """
            Tightened contract: all-nil identity must NOT pick from cwd. \
            Tab restores blank; user re-runs the AI command manually.
            """
        )
    }

    /// Realistic recoverable case: provider tag survived (synthetic-id
    /// autosave window). Re-resolution should produce the codex session
    /// matching the directory.
    func testProviderTagOnlyResolvesForEAE7B456WithCodexTag() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CHAU7_RUN_RESUME_PROOF"] == "1",
            "Diagnostic test — set CHAU7_RUN_RESUME_PROOF=1 to enable"
        )

        let pane = SavedTerminalPaneState(
            paneID: "599EEB9D-7426-43D3-BD3C-CB8D34791444",
            directory: "/Users/christophehenner/Downloads/Repositories/github-telegram-bot",
            scrollbackContent: nil,
            aiResumeCommand: nil,
            aiResumeDirectory: nil,
            aiProvider: "codex",
            aiSessionId: nil,
            aiSessionIdSource: nil,
            lastOutputAt: Date(timeIntervalSinceReferenceDate: 803_136_107),
            lastInputAt: Date(timeIntervalSinceReferenceDate: 803_136_107)
        )

        guard let resolved = OverlayTabsModel.reResolveResumeCommand(paneState: pane) else {
            XCTFail(
                """
                Re-resolution returned nil for tab EAE7B456 with codex tag.
                Saved directory: /Users/christophehenner/Downloads/Repositories/github-telegram-bot
                Expected: a codex resume command for the June 12 session.
                Possible causes: codex sessions not on this machine, or the
                day-window expansion didn't reach back far enough.
                """
            )
            return
        }
        XCTAssertEqual(resolved.provider, "codex")
        // Diagnostic-only print: the purpose of this gated test is to
        // surface the resolved trio to the test console so the developer
        // can eyeball it.
        // swiftlint:disable:next no_print_statements
        print("PROOF tab=EAE7B456 → provider=\(resolved.provider) session=\(resolved.sessionId) cmd=\(resolved.command)")
    }
}
#endif
