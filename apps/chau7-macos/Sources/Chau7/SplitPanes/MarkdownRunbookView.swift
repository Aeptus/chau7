import SwiftUI
import Chau7Core

/// Renders a markdown file with executable code blocks.
/// Each fenced code block (```bash, ```sh, ```) gets a "Run" button
/// that sends the code to the terminal session in the same tab.
struct MarkdownRunbookView: View {
    let content: String
    let fileName: String
    /// Single bundled surface the runbook needs from its host (the editor
    /// model). Replaces what used to be five separate closure parameters
    /// (`onRunBlock`, `onRunAll`, `codeBlockState`, `onToggleCheckbox`,
    /// `onContentChange`) the caller had to wire individually.
    let host: any RunbookHost

    /// Cached parse output keyed by content. `body` runs on every code-block
    /// state change (e.g. running → succeeded recolouring borders) so a
    /// computed-every-time parse re-walks the full markdown on each tick —
    /// expensive for long runbooks. We refresh the cache via `.task(id:)`
    /// whenever the underlying content actually changes.
    @State private var cachedContent: String?
    @State private var cachedSections: [MarkdownSection] = []

    private var sections: [MarkdownSection] {
        if cachedContent == content { return cachedSections }
        // Cold path on first render — `.task(id: content)` will populate the
        // cache after this frame so all later renders for the same content
        // hit the fast path.
        return parseMarkdown(content)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    switch section.kind {
                    case .text(let text):
                        Text(Self.renderInlineMarkdown(text))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)

                    case .heading(let level, let text):
                        Text(Self.renderInlineMarkdown(text))
                            .font(fontForHeading(level))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, level == 1 ? 8 : 4)

                    case .codeBlock(let lang, let code, let lineNumber):
                        codeBlockView(language: lang, code: code, lineNumber: lineNumber)

                    case .checkboxItem(let checked, let text, let lineNumber):
                        checkboxItemView(checked: checked, text: text, lineNumber: lineNumber)

                    case .bulletItem(let text, _):
                        bulletItemView(text: text)

                    case .numberedItem(let number, let text, _):
                        numberedItemView(number: number, text: text)

                    case .horizontalRule:
                        Divider()
                            .padding(.vertical, 4)
                    }
                }
            }
            .padding()
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: content) {
            // `.task(id:)` fires once per distinct content value, including
            // on initial appearance, so the cache is correct after the first
            // frame and stays correct across the user's keystrokes.
            cachedSections = parseMarkdown(content)
            cachedContent = content
        }
    }

    /// Convert an inline-markdown string (the body of a paragraph, heading,
    /// list item, or checkbox) into an `AttributedString` so SwiftUI's
    /// `Text` renders `**bold**`, `*italic*`, `` `code` ``, and `[link](url)`
    /// as actual styled glyphs instead of literal characters.
    ///
    /// `.inlineOnlyPreservingWhitespace` tells the parser to handle the
    /// inline constructs only — block constructs (headings, lists, fences)
    /// have already been peeled off by `parseMarkdown` in the infrastructure
    /// layer, so we don't want the markdown engine reinterpreting them.
    /// Preserving whitespace matters for content where the user has
    /// intentional spacing (multi-space alignment inside a list item, etc.).
    ///
    /// On malformed input the markdown parser throws — fall back to a
    /// plain-text `AttributedString` so we never render literal `**` or
    /// drop the content silently.
    static func renderInlineMarkdown(_ text: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        if let attributed = try? AttributedString(markdown: text, options: opts) {
            return attributed
        }
        return AttributedString(text)
    }

    private func codeBlockView(language: String?, code: String, lineNumber: Int) -> some View {
        let state = host.codeBlockState(for: code, lineNumber: lineNumber)
        let borderColor: Color = switch state {
        case .running: .orange
        case .succeeded: .green
        case .failed: .red
        case .none: Color(nsColor: .separatorColor)
        }
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let lang = language, !lang.isEmpty {
                    Text(verbatim: lang)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if let state {
                    Text(verbatim: label(for: state))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(color(for: state))
                }
                Spacer()
                Button {
                    host.runBlock(code, lineNumber: lineNumber)
                } label: {
                    Label(L("pane.run", "Run"), systemImage: "play.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))

            // Explicit verbatim: a code block must never be re-interpreted
            // as markdown. SwiftUI's `Text(_ content: some StringProtocol)`
            // overload happens not to interpret markdown today, but pinning
            // to `Text(verbatim:)` documents the intent and survives future
            // overload changes.
            Text(verbatim: code)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(borderColor, lineWidth: state == nil ? 0.5 : 1)
        }
    }

    private func checkboxItemView(checked: Bool, text: String, lineNumber: Int) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Button {
                host.toggleCheckbox(lineNumber: lineNumber)
            } label: {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(checked ? Color.accentColor : .secondary)
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)

            Text(Self.renderInlineMarkdown(text))
                .strikethrough(checked)
                .foregroundStyle(checked ? .secondary : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 4)
    }

    private func bulletItemView(text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(verbatim: "•")
                .foregroundStyle(.secondary)
            Text(Self.renderInlineMarkdown(text))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func numberedItemView(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(verbatim: "\(number).")
                .foregroundStyle(.secondary)
            Text(Self.renderInlineMarkdown(text))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func fontForHeading(_ level: Int) -> Font {
        switch level {
        case 1: return .system(size: 22, weight: .bold)
        case 2: return .system(size: 18, weight: .semibold)
        case 3: return .system(size: 15, weight: .semibold)
        default: return .system(size: 13, weight: .medium)
        }
    }

    private func label(for state: RunbookCodeBlockState) -> String {
        switch state {
        case .running: return L("pane.commandRunning", "Running")
        case .succeeded: return L("pane.commandSuccess", "Succeeded")
        case .failed: return L("pane.commandFailed", "Failed")
        }
    }

    private func color(for state: RunbookCodeBlockState) -> Color {
        switch state {
        case .running: return .orange
        case .succeeded: return .green
        case .failed: return .red
        }
    }
}
