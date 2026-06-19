#if canImport(AppKit)
import XCTest
import Chau7Core
@testable import Chau7

/// **NOT a regression test — a diagnostic.** Runs the production
/// `reResolveResumeCommand` against the real saved state of the two tabs
/// the user has been complaining about, against the real Codex / Claude
/// transcripts on the developer's home directory. Either prints what the
/// resolver returns (the fix works for those specific tabs) or fails with
/// a clear diagnostic explaining what's missing.
///
/// Gated on a env var so CI never runs it — it's a once-per-investigation
/// gun we point at a specific machine. Set
/// `CHAU7_RUN_RESUME_PROOF=1` to enable.
final class ReResolveResumeCommandIntegrationProof: XCTestCase {

    func testProofForEAE7B456() throws {
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
            lastOutputAt: Date(timeIntervalSinceReferenceDate: 803136107),
            lastInputAt: Date(timeIntervalSinceReferenceDate: 803136107)
        )

        guard let resolved = OverlayTabsModel.reResolveResumeCommand(paneState: pane) else {
            XCTFail(
                """
                Re-resolution returned nil for tab EAE7B456.
                Saved directory: /Users/christophehenner/Downloads/Repositories/github-telegram-bot
                Expected: a codex resume command for the June 12 session.
                Possible causes: codex sessions not on this machine, or the
                day-window expansion didn't reach back far enough.
                """
            )
            return
        }
        print("PROOF tab=EAE7B456 → provider=\(resolved.provider) session=\(resolved.sessionId) cmd=\(resolved.command)")
    }
}
#endif
