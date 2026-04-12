import SwiftUI
import Chau7Core

/// Renders a markdown file with executable code blocks.
/// Each fenced code block (```bash, ```sh, ```) gets a "Run" button
/// that sends the code to the terminal session in the same tab.
struct MarkdownRunbookView: View {
    let content: String
    let fileName: String
    let onRunBlock: (String, Int) -> Void
    let onRunAll: () -> Void
    var codeBlockState: ((String, Int) -> RunbookCodeBlockState?)?
    var onToggleCheckbox: ((Int) -> Void)?
    var onContentChange: ((String) -> Void)?

    private var sections: [MarkdownSection] {
        parseMarkdown(content)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    switch section.kind {
                    case .text(let text):
                        Text(verbatim: text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                    case .heading(let level, let text):
                        Text(verbatim: text)
                            .font(fontForHeading(level))
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
    }

    private func codeBlockView(language: String?, code: String, lineNumber: Int) -> some View {
        let state = codeBlockState?(code, lineNumber)
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
                    Text(label(for: state))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(color(for: state))
                }
                Spacer()
                Button {
                    onRunBlock(code, lineNumber)
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

            Text(code)
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
                if let onToggleCheckbox {
                    onToggleCheckbox(lineNumber)
                } else {
                    let newContent = toggleCheckboxInContent(content, lineNumber: lineNumber)
                    onContentChange?(newContent)
                }
            } label: {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(checked ? Color.accentColor : .secondary)
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)

            Text(verbatim: text)
                .strikethrough(checked)
                .foregroundStyle(checked ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 4)
    }

    private func bulletItemView(text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .foregroundStyle(.secondary)
            Text(verbatim: text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func numberedItemView(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number).")
                .foregroundStyle(.secondary)
            Text(verbatim: text)
                .textSelection(.enabled)
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
