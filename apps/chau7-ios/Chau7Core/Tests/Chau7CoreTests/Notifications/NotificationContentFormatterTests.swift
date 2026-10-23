import XCTest
@testable import Chau7Core

/// Snapshot-parity tests: `NotificationContentFormatter` output must match
/// the strings that shipped in the four formatters it absorbed —
/// `AIEvent.notificationTitle/Subtitle/Body`, `RemoteActivityProjection`'s
/// headline, the Go agent's `pushApprovalTitle`/`locationSummary`, and the
/// iOS `RemoteNotificationScheduler` strings.
final class NotificationContentFormatterTests: XCTestCase {

    private func event(
        type: String,
        tool: String = "Claude Code",
        message: String = "",
        directory: String? = nil,
        repoPath: String? = nil
    ) -> AIEvent {
        AIEvent(
            source: .claudeCode, type: type, tool: tool, message: message,
            ts: DateFormatters.nowISO8601(), directory: directory, repoPath: repoPath
        )
    }

    // MARK: - AIEvent title/body/subtitle (parity via the public shims)

    func testTitleSuffixesForAllKnownTypes() {
        let expectations: [(String, String)] = [
            ("needs_validation", "Needs review"),
            ("idle", "Waiting for input"),
            ("waiting_input", "Waiting for input"),
            ("attention_required", "Needs attention"),
            ("finished", "Finished"),
            ("failed", "Failed"),
            ("permission", "Permission needed"),
            ("error", "Error"),
            ("context_limit", "Context limit reached"),
            ("file_conflict", "File conflict"),
            ("tool_called", "Tool called"),
            ("file_edited", "File edited"),
            ("token_threshold", "Token threshold"),
            ("cost_threshold", "Cost threshold"),
            ("something_new", "Update")
        ]
        for (type, suffix) in expectations {
            XCTAssertEqual(
                NotificationContentFormatter.title(for: event(type: type)),
                "Claude Code: \(suffix)",
                "title drifted for type \(type)"
            )
        }
    }

    func testTitleRepoPrefixAndToolOverride() {
        let base = event(type: "finished")
        XCTAssertEqual(
            NotificationContentFormatter.title(for: base, repoName: "Mockup"),
            "Mockup — Claude Code: Finished"
        )
        XCTAssertEqual(
            NotificationContentFormatter.title(for: base, toolOverride: "Claude"),
            "Claude: Finished"
        )
        // Repo equal to tool name collapses to the plain prefix.
        XCTAssertEqual(
            NotificationContentFormatter.title(for: base, repoName: "Claude Code"),
            "Claude Code: Finished"
        )
        // Shim delegates.
        XCTAssertEqual(base.notificationTitle, NotificationContentFormatter.title(for: base))
    }

    func testBodyPrefersProducerMessageAndFallsBackToLocalizedDefault() {
        XCTAssertEqual(NotificationContentFormatter.body(for: event(type: "finished")), "Done.")
        XCTAssertEqual(NotificationContentFormatter.body(for: event(type: "finished", message: "All tests pass")), "All tests pass")
        XCTAssertEqual(NotificationContentFormatter.body(for: event(type: "failed")), "Check the logs.")
        XCTAssertEqual(NotificationContentFormatter.body(for: event(type: "permission")), "Needs your permission to continue.")
        XCTAssertEqual(NotificationContentFormatter.body(for: event(type: "custom_type")), "custom_type")
        XCTAssertEqual(NotificationContentFormatter.body(for: event(type: "custom_type", message: "hi")), "custom_type: hi")
        // Shim delegates.
        let sample = event(type: "waiting_input")
        XCTAssertEqual(sample.notificationBody, NotificationContentFormatter.body(for: sample))
    }

    func testSubtitlePartsAndDeduplication() {
        let withRepo = event(type: "finished", repoPath: "/Users/me/Projects/Mockup")
        XCTAssertEqual(
            NotificationContentFormatter.subtitle(for: withRepo, tabTitle: "build"),
            "Repo: Mockup · Tab: build"
        )
        // Tab that repeats the repo or tool is dropped.
        XCTAssertEqual(
            NotificationContentFormatter.subtitle(for: withRepo, tabTitle: "Mockup"),
            "Repo: Mockup"
        )
        XCTAssertEqual(
            NotificationContentFormatter.subtitle(for: withRepo, tabTitle: "claude code"),
            "Repo: Mockup"
        )
        // Directory fallback when no repo.
        let withDir = event(type: "finished", directory: "/tmp/scratch")
        XCTAssertEqual(NotificationContentFormatter.subtitle(for: withDir), "Dir: scratch")
        // Shim delegates.
        XCTAssertEqual(
            withRepo.notificationSubtitle(tabTitle: "build"),
            NotificationContentFormatter.subtitle(for: withRepo, tabTitle: "build")
        )
    }

    // MARK: - Approval / prompt titles (parity with Go pushApprovalTitle + iOS)

    func testApprovalTitleMatchesGoAndIOSSemantics() {
        XCTAssertEqual(
            NotificationContentFormatter.approvalTitle(toolName: "Codex", isProtectedAction: false),
            "Codex needs approval"
        )
        XCTAssertEqual(
            NotificationContentFormatter.approvalTitle(toolName: nil, isProtectedAction: false),
            "Command approval"
        )
        XCTAssertEqual(
            NotificationContentFormatter.approvalTitle(toolName: "   ", isProtectedAction: false),
            "Command approval"
        )
        XCTAssertEqual(
            NotificationContentFormatter.approvalTitle(toolName: "Codex", isProtectedAction: true),
            "Protected action needs approval"
        )
    }

    func testInteractivePromptTitle() {
        XCTAssertEqual(NotificationContentFormatter.interactivePromptTitle(toolName: "Claude"), "Claude is waiting")
        XCTAssertEqual(NotificationContentFormatter.interactivePromptTitle(toolName: nil), "Interactive prompt")
        XCTAssertEqual(NotificationContentFormatter.interactivePromptTitle(toolName: " "), "Interactive prompt")
    }

    // MARK: - Location summary (parity with Go locationSummary + iOS subtitle)

    func testLocationSummaryComposition() {
        XCTAssertEqual(
            NotificationContentFormatter.locationSummary(
                tabTitle: "build", projectName: "Mockup", branchName: "main",
                currentDirectory: "/srv/app"
            ),
            "build · Mockup (main) · /srv/app"
        )
        XCTAssertEqual(
            NotificationContentFormatter.locationSummary(
                tabTitle: nil, projectName: "Mockup", branchName: nil, currentDirectory: nil
            ),
            "Mockup"
        )
        XCTAssertEqual(
            NotificationContentFormatter.locationSummary(
                tabTitle: nil, projectName: nil, branchName: "main", currentDirectory: nil
            ),
            "main"
        )
        XCTAssertNil(
            NotificationContentFormatter.locationSummary(
                tabTitle: " ", projectName: nil, branchName: nil, currentDirectory: nil
            )
        )
    }

    func testLocationSummaryHomeAbbreviationOnlyWhenRequested() {
        let home = NSHomeDirectory()
        // Wire/Go semantics: no home abbreviation.
        XCTAssertEqual(
            NotificationContentFormatter.locationSummary(
                tabTitle: nil, projectName: nil, branchName: nil,
                currentDirectory: "\(home)/code"
            ),
            "\(home)/code"
        )
        // iOS local-notification semantics: abbreviate under home.
        XCTAssertEqual(
            NotificationContentFormatter.locationSummary(
                tabTitle: nil, projectName: nil, branchName: nil,
                currentDirectory: "\(home)/code", homeDirectory: home
            ),
            "~/code"
        )
        XCTAssertEqual(
            NotificationContentFormatter.locationSummary(
                tabTitle: nil, projectName: nil, branchName: nil,
                currentDirectory: home, homeDirectory: home
            ),
            "~"
        )
    }

    // MARK: - Activity headline (parity with RemoteActivityProjection)

    func testActivityHeadlineParity() {
        XCTAssertEqual(NotificationContentFormatter.activityHeadline(status: .approvalRequired, toolName: "Codex"), "Approval required")
        XCTAssertEqual(NotificationContentFormatter.activityHeadline(status: .waitingInput, toolName: "Codex"), "Codex needs input")
        XCTAssertEqual(NotificationContentFormatter.activityHeadline(status: .failed, toolName: "Codex"), "Codex failed")
        XCTAssertEqual(NotificationContentFormatter.activityHeadline(status: .running, toolName: "Codex"), "Codex is active")
        XCTAssertEqual(NotificationContentFormatter.activityHeadline(status: .completed, toolName: "Codex"), "Codex finished")
        XCTAssertEqual(NotificationContentFormatter.activityHeadline(status: .idle, toolName: "Codex"), "Codex")
    }

    // MARK: - AppleScript quoting

    func testAppleScriptQuoted() {
        XCTAssertEqual(#"say "hi""#.appleScriptQuoted, #"say \"hi\""#)
        XCTAssertEqual("back\\slash".appleScriptQuoted, "back\\\\slash")
        XCTAssertEqual("line1\nline2\r".appleScriptQuoted, "line1 line2")
    }
}
