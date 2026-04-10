import SwiftUI

/// Renders a markdown file with executable code blocks.
/// Each fenced code block (```bash, ```sh, ```) gets a "Run" button
/// that sends the code to the terminal session in the same tab.
struct MarkdownRunbookView: View {
    let content: String
    let fileName: String
    let onRunBlock: (String) -> Void
    let onRunAll: () -> Void
    var onContentChange: ((String) -> Void)?

    private var sections: [MarkdownSection] {
        parseMarkdown(content)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(sections) { section in
                    switch section.kind {
                    case .text(let text):
                        Text(LocalizedStringKey(text))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                    case .heading(let level, let text):
                        Text(text)
                            .font(fontForHeading(level))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, level == 1 ? 8 : 4)

                    case .codeBlock(let lang, let code):
                        codeBlockView(language: lang, code: code)

                    case .checkboxItem(let checked, let text, let lineNumber):
                        checkboxItemView(checked: checked, text: text, lineNumber: lineNumber)
                    }
                }
            }
            .padding()
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func codeBlockView(language: String?, code: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with language tag and Run button
            HStack {
                if let lang = language, !lang.isEmpty {
                    Text(lang)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    onRunBlock(code)
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

            // Code content
            Text(code)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    private func checkboxItemView(checked: Bool, text: String, lineNumber: Int) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Button {
                let newContent = toggleCheckboxInContent(content, lineNumber: lineNumber)
                onContentChange?(newContent)
            } label: {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(checked ? .accentColor : .secondary)
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)

            Text(LocalizedStringKey(text))
                .strikethrough(checked)
                .foregroundStyle(checked ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 4)
    }

    private func fontForHeading(_ level: Int) -> Font {
        switch level {
        case 1: return .system(size: 22, weight: .bold)
        case 2: return .system(size: 18, weight: .semibold)
        case 3: return .system(size: 15, weight: .semibold)
        default: return .system(size: 13, weight: .medium)
        }
    }
}

// MARK: - Markdown Parsing

enum MarkdownSectionKind {
    case heading(level: Int, text: String)
    case text(String)
    case codeBlock(language: String?, code: String)
    case checkboxItem(checked: Bool, text: String, lineNumber: Int)
}

struct MarkdownSection: Identifiable {
    let id = UUID()
    let kind: MarkdownSectionKind
}

/// Lightweight markdown parser — extracts headings, text blocks, and fenced code blocks.
/// Not a full CommonMark parser; handles the 95% case for runbooks.
func parseMarkdown(_ input: String) -> [MarkdownSection] {
    var sections: [MarkdownSection] = []
    let lines = input.components(separatedBy: "\n")
    var i = 0
    var textAccum = ""

    func flushText() {
        let trimmed = textAccum.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            sections.append(MarkdownSection(kind: .text(trimmed)))
        }
        textAccum = ""
    }

    while i < lines.count {
        let line = lines[i]

        // Fenced code block
        if line.hasPrefix("```") {
            flushText()
            let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            var codeLines: [String] = []
            i += 1
            while i < lines.count, !lines[i].hasPrefix("```") {
                codeLines.append(lines[i])
                i += 1
            }
            let code = codeLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !code.isEmpty {
                sections.append(MarkdownSection(kind: .codeBlock(language: lang.isEmpty ? nil : lang, code: code)))
            }
            if i < lines.count { i += 1 } // skip closing ``` (guard unclosed block)
            continue
        }

        // Heading
        if line.hasPrefix("#") {
            flushText()
            var level = 0
            for ch in line {
                if ch == "#" { level += 1 } else { break }
            }
            let text = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
            sections.append(MarkdownSection(kind: .heading(level: min(level, 4), text: text)))
            i += 1
            continue
        }

        // Checkbox item: - [ ] text, - [x] text, * [ ] text, * [x] text
        if let match = parseCheckboxLine(line) {
            flushText()
            sections.append(MarkdownSection(kind: .checkboxItem(checked: match.checked, text: match.text, lineNumber: i)))
            i += 1
            continue
        }

        // Regular text
        textAccum += line + "\n"
        i += 1
    }

    flushText()
    return sections
}

/// Parses a single line for checkbox syntax: `- [ ] text` or `- [x] text` (also `*` bullets).
private func parseCheckboxLine(_ line: String) -> (checked: Bool, text: String)? {
    let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
    guard let first = trimmed.first, (first == "-" || first == "*") else { return nil }
    let afterBullet = trimmed.dropFirst()
    guard afterBullet.hasPrefix(" [") else { return nil }
    let afterBracket = afterBullet.dropFirst(2) // drop " ["
    guard let marker = afterBracket.first else { return nil }
    let checked: Bool
    switch marker {
    case "x", "X": checked = true
    case " ": checked = false
    default: return nil
    }
    let rest = afterBracket.dropFirst() // drop the marker character
    guard rest.hasPrefix("] ") else { return nil }
    let text = String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return nil }
    return (checked, text)
}

/// Returns new content with the checkbox on the given line toggled.
func toggleCheckboxInContent(_ content: String, lineNumber: Int) -> String {
    var lines = content.components(separatedBy: "\n")
    guard lineNumber >= 0, lineNumber < lines.count else { return content }
    let line = lines[lineNumber]
    if line.contains("[ ]") {
        lines[lineNumber] = line.replacingOccurrences(of: "[ ]", with: "[x]", range: line.range(of: "[ ]"))
    } else if let range = line.range(of: "[x]", options: .caseInsensitive) {
        lines[lineNumber] = line.replacingCharacters(in: range, with: "[ ]")
    }
    return lines.joined(separator: "\n")
}
