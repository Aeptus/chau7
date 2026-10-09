import Foundation
import Chau7Core

/// What the `MarkdownRunbookView` needs from whatever's hosting it. The
/// view used to take five separate closures (`onRunBlock`, `onRunAll`,
/// `codeBlockState`, `onToggleCheckbox`, `onContentChange`) which forced
/// every caller to thread five bindings even when they only cared about
/// one. This protocol collapses those into one focused surface —
/// callers conform once and the view consumes them via a single
/// `host: any RunbookHost` parameter.
///
/// ISP win: callers that only need the render (no run, no checkbox toggle)
/// can ship a no-op conformer instead of supplying five separate closures
/// each.
/// `@MainActor` because the only consumer is `MarkdownRunbookView`, a SwiftUI
/// view, and the requirements all mutate view-backed state: running a block
/// updates the runbook's tracked state, and toggling a checkbox rewrites the
/// host editor's buffer.
@MainActor
protocol RunbookHost {
    /// Run a single fenced code block against the host terminal session.
    /// `lineNumber` identifies the block's position in the markdown source
    /// so the host can attribute completion back to a UI element.
    func runBlock(_ code: String, language: String?, lineNumber: Int)

    /// Returns the current run state for a tracked block, or nil when the
    /// block has not been queued yet.
    func codeBlockState(for code: String, lineNumber: Int) -> RunbookCodeBlockState?

    /// Toggle the markdown checkbox at `lineNumber` — used by the
    /// interactive checkbox items in the rendered runbook.
    func toggleCheckbox(lineNumber: Int)

    /// Persist a content edit back to the source buffer — used by the
    /// host when an interactive element (e.g. checkbox toggle) needs to
    /// flow through the file buffer.
    func updateContent(_ newContent: String)
}

/// Adapter wiring a `TextEditorModel` + a "send command to terminal"
/// closure into a single `RunbookHost`. The editor owns the runbook
/// state machine (`runbook.codeBlockState`, `runMarkdownBlocksSequentially`)
/// and the file buffer (`toggleCheckbox`, `updateContent`); the closure
/// covers the terminal-side execution that the editor itself doesn't own.
/// `TextEditorPaneView` builds one and hands it to `MarkdownRunbookView`,
/// so the view receives one focused object instead of five closures.
struct RunbookHostAdapter: RunbookHost {
    let editor: TextEditorModel
    /// Forwards a block to the terminal session. Captures whatever the
    /// pane's `onRunCommand` closure resolved to (the controller's
    /// `sendCommandToTerminal` route in production).
    let sendCommand: (String, Int) -> Void

    func runBlock(_ code: String, language: String?, lineNumber: Int) {
        guard RunbookShellExecution.supports(language: language) else {
            let label = language?.split(whereSeparator: { $0.isWhitespace || $0 == "," }).first.map(String.init) ?? "unknown"
            editor.lastError = L("pane.unsupportedRunbookLanguage", "This code block is labelled \(label) and will not be sent to the shell.")
            return
        }
        sendCommand("\(code)\n", lineNumber)
    }

    func codeBlockState(for code: String, lineNumber: Int) -> RunbookCodeBlockState? {
        editor.codeBlockState(for: code, lineNumber: lineNumber)
    }

    func toggleCheckbox(lineNumber: Int) {
        editor.toggleCheckbox(lineNumber: lineNumber)
    }

    func updateContent(_ newContent: String) {
        editor.updateContent(newContent)
    }
}
