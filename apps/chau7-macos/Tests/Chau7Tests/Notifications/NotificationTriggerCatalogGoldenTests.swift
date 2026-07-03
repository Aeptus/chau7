import XCTest
@testable import Chau7Core

/// Golden snapshot of the entire trigger catalog surface.
///
/// The catalog's localization keys, fallbacks, and defaults are persisted user
/// state (trigger IDs) and shipped localization keys — any drift is a breaking
/// change. This test hardcodes the expected set so that a refactor of how the
/// catalog is *built* (derivation from `AIToolRegistry`, spec-table builders)
/// cannot silently change *what* it contains. If you intentionally add or
/// change a trigger, update the golden table here in the same commit.
final class NotificationTriggerCatalogGoldenTests: XCTestCase {

    private struct GoldenTrigger: Hashable {
        let id: String
        let labelKey: String
        let labelFallback: String
        let descriptionKey: String
        let descriptionFallback: String
        let defaultEnabled: Bool
    }

    // MARK: - Golden constants

    /// (source raw value, camelCase localization segment, display name)
    /// for every AI source that shares the common trigger matrix.
    private static let aiSources: [(raw: String, camel: String, name: String)] = [
        ("claude_code", "claudeCode", "Claude Code"),
        ("codex", "codex", "Codex"),
        ("gemini", "gemini", "Gemini"),
        ("chatgpt", "chatgpt", "ChatGPT"),
        ("cursor", "cursor", "Cursor"),
        ("windsurf", "windsurf", "Windsurf"),
        ("copilot", "copilot", "GitHub Copilot"),
        ("aider", "aider", "Aider"),
        ("cline", "cline", "Cline"),
        ("cody", "cody", "Cody"),
        ("amazon_q", "amazonQ", "Amazon Q"),
        ("devin", "devin", "Devin"),
        ("goose", "goose", "Goose"),
        ("mentat", "mentat", "Mentat"),
        ("amp", "amp", "Amp"),
        ("continue_ai", "continueAI", "Continue"),
        ("runtime", "runtime", "Runtime Agent")
    ]

    /// (type, camelCase key segment, label, description suffix, defaultEnabled)
    /// for the shared AI trigger matrix.
    private static let aiTriggerTypes: [(type: String, camel: String, label: String, desc: String, enabled: Bool)] = [
        ("finished", "finished", "Response complete", "finished responding.", true),
        ("failed", "failed", "Task failed", "failed or exited with an error.", true),
        ("permission", "permission", "Permission request", "needs permission to continue.", true),
        ("waiting_input", "waitingInput", "Waiting for input", "is waiting for your input.", true),
        ("attention_required", "attentionRequired", "Needs attention", "needs your attention.", true),
        ("tool_failed", "toolFailed", "Tool failed", "tool execution failed.", false),
        ("response_failed", "responseFailed", "Response failed", "response ended with an error.", true),
        ("elicitation", "elicitation", "MCP input request", "MCP server requesting user input.", true),
        ("authentication_succeeded", "authenticationSucceeded", "Authentication complete", "completed authentication.", false),
        ("idle", "idle", "Session idle", "session appears idle.", false),
        ("token_threshold", "tokenThreshold", "Token threshold", "Token usage exceeded threshold.", false),
        ("cost_threshold", "costThreshold", "Cost threshold", "Session cost exceeded threshold.", false),
        ("tool_called", "toolCalled", "Tool called", "called a tool.", false),
        ("file_edited", "fileEdited", "File edited", "edited a file.", false),
        ("error", "error", "Error occurred", "encountered an error.", false),
        ("context_limit", "contextLimit", "Context limit", "approaching context window limit.", false),
        ("*", "other", "Other events", "event types.", false)
    ]

    private static let aiGolden: [GoldenTrigger] = aiSources.flatMap { src in
        aiTriggerTypes.map { tt in
            GoldenTrigger(
                id: "\(src.raw).\(tt.type)",
                labelKey: "notifications.trigger.\(src.camel).\(tt.camel).label",
                labelFallback: tt.type == "*" ? "Other \(src.name) events" : tt.label,
                descriptionKey: "notifications.trigger.\(src.camel).\(tt.camel).description",
                descriptionFallback: tt.type == "*"
                    ? "Any other \(src.name) event types."
                    : "\(src.name) \(tt.desc)",
                defaultEnabled: tt.enabled
            )
        }
    }

    /// Builds one non-AI golden row from (source raw, source camel, type,
    /// type camel, label, description, defaultEnabled).
    private static func golden(
        _ sourceRaw: String,
        _ sourceCamel: String,
        _ type: String,
        _ typeCamel: String,
        _ label: String,
        _ description: String,
        _ defaultEnabled: Bool
    ) -> GoldenTrigger {
        GoldenTrigger(
            id: "\(sourceRaw).\(type)",
            labelKey: "notifications.trigger.\(sourceCamel).\(typeCamel).label",
            labelFallback: label,
            descriptionKey: "notifications.trigger.\(sourceCamel).\(typeCamel).description",
            descriptionFallback: description,
            defaultEnabled: defaultEnabled
        )
    }

    private static let nonAIGolden: [GoldenTrigger] = [
        // events_log
        golden("events_log", "eventsLog", "finished", "finished", "Task finished", "An AI event reports a completed task.", true),
        golden("events_log", "eventsLog", "failed", "failed", "Task failed", "An AI event reports a failure or error.", true),
        golden("events_log", "eventsLog", "needs_validation", "needsValidation", "Needs validation", "An AI event requests review or confirmation.", false),
        golden("events_log", "eventsLog", "permission", "permission", "Permission request", "An AI event requests permission to proceed.", true),
        golden("events_log", "eventsLog", "tool_complete", "toolComplete", "Tool complete", "An AI event reports a tool finished executing.", false),
        golden("events_log", "eventsLog", "session_end", "sessionEnd", "Session ended", "An AI event reports a session ended.", false),
        golden("events_log", "eventsLog", "idle", "idle", "Command idle", "An AI event reports inactivity or waiting for input.", false),
        golden("events_log", "eventsLog", "notification", "notification", "Custom notification", "An AI event requests a custom notification.", false),
        golden("events_log", "eventsLog", "*", "other", "Other events", "Any other AI event types not listed above.", false),
        // terminal_session
        golden("terminal_session", "terminalSession", "finished", "finished", "AI tool finished", "An AI tool finished in the terminal.", true),
        golden("terminal_session", "terminalSession", "permission", "permission", "AI tool needs permission", "An AI tool in the terminal needs permission to continue.", true),
        golden("terminal_session", "terminalSession", "idle", "idle", "Command idle", "Terminal command produced no output for the idle timeout.", false),
        golden("terminal_session", "terminalSession", "failed", "failed", "Shell exited", "Terminal shell process exited.", true),
        golden("terminal_session", "terminalSession", "info", "info", "AI tool started", "An AI tool started in the terminal.", false),
        // history_monitor
        golden("history_monitor", "historyMonitor", "finished", "finished", "Session completed (history)", "AI session completed as detected by history file monitoring.", true),
        golden("history_monitor", "historyMonitor", "idle", "idle", "History idle", "No new history entries for the idle timeout.", false),
        // shell
        golden("shell", "shell", "command_finished", "commandFinished", "Command finished", "A shell command completed execution.", false),
        golden("shell", "shell", "command_failed", "commandFailed", "Command failed", "A shell command exited with non-zero status.", false),
        golden("shell", "shell", "exit_code_match", "exitCodeMatch", "Exit code match", "Command exited with a specific exit code.", false),
        golden("shell", "shell", "pattern_match", "patternMatch", "Output pattern match", "Command output matched a configured pattern.", false),
        golden("shell", "shell", "long_running", "longRunning", "Long-running command", "Command has been running longer than threshold.", false),
        golden("shell", "shell", "process_started", "processStarted", "Process started", "A new process was started in the shell.", false),
        golden("shell", "shell", "process_ended", "processEnded", "Process ended", "A shell process has terminated.", false),
        golden("shell", "shell", "directory_changed", "directoryChanged", "Directory changed", "Working directory was changed (cd).", false),
        golden("shell", "shell", "git_branch_changed", "gitBranchChanged", "Git branch changed", "Git branch was switched or changed.", false),
        golden("shell", "shell", "*", "other", "Other shell events", "Any other shell event types.", false),
        // app
        golden("app", "app", "launch", "launch", "App launched", "The app was launched.", false),
        golden("app", "app", "update_available", "updateAvailable", "Update available", "A new version is available.", true),
        golden("app", "app", "file_conflict", "fileConflict", "File conflict detected", "Multiple tabs modified the same file, risking merge conflicts.", true),
        golden("app", "app", "memory_threshold", "memoryThreshold", "Memory threshold", "Memory usage exceeded threshold.", false),
        golden("app", "app", "tab_opened", "tabOpened", "Tab opened", "A new tab was opened.", false),
        golden("app", "app", "tab_closed", "tabClosed", "Tab closed", "A tab was closed.", false),
        golden("app", "app", "window_focused", "windowFocused", "Window focused", "App window gained focus.", false),
        golden("app", "app", "window_unfocused", "windowUnfocused", "Window unfocused", "App window lost focus.", false),
        golden("app", "app", "file_modified", "fileModified", "File modified", "A watched file was modified.", false),
        golden("app", "app", "docker_event", "dockerEvent", "Docker event", "A Docker container event occurred.", false),
        golden("app", "app", "*", "other", "Other app events", "Any other app event types.", false),
        // api_proxy
        golden("api_proxy", "apiProxy", "*", "other", "API Proxy events", "Any event from the API proxy.", false),
        // unknown
        golden("unknown", "unknown", "*", "other", "Unknown source events", "Events from unrecognized sources.", false)
    ]

    // MARK: - Tests

    func testCatalogMatchesGoldenSnapshot() {
        let expected = Set(Self.aiGolden + Self.nonAIGolden)
        let actual = Set(NotificationTriggerCatalog.all.map { trigger in
            GoldenTrigger(
                id: trigger.id,
                labelKey: trigger.labelKey,
                labelFallback: trigger.labelFallback,
                descriptionKey: trigger.descriptionKey,
                descriptionFallback: trigger.descriptionFallback,
                defaultEnabled: trigger.defaultEnabled
            )
        })

        XCTAssertEqual(actual.count, NotificationTriggerCatalog.all.count, "catalog contains duplicate trigger rows")

        let missing = expected.subtracting(actual).map(\.id).sorted()
        let extra = actual.subtracting(expected).map(\.id).sorted()
        XCTAssertTrue(missing.isEmpty, "triggers missing or drifted from golden snapshot: \(missing)")
        XCTAssertTrue(extra.isEmpty, "unexpected triggers not in golden snapshot: \(extra)")
    }

    func testActivityOnlyDisplayContextsMatchGolden() {
        // The only activity-only (hidden from settings) triggers are the four
        // emitter-less app triggers; everything else shows in settings+activity.
        let activityOnly = Set(
            NotificationTriggerCatalog.all
                .filter { $0.displayContexts == [.activity] }
                .map(\.id)
        )
        XCTAssertEqual(
            activityOnly,
            ["app.window_focused", "app.window_unfocused", "app.file_modified", "app.docker_event"]
        )
        for trigger in NotificationTriggerCatalog.all where !activityOnly.contains(trigger.id) {
            XCTAssertEqual(
                trigger.displayContexts, [.settings, .activity],
                "\(trigger.id) has unexpected display contexts"
            )
        }
    }
}
