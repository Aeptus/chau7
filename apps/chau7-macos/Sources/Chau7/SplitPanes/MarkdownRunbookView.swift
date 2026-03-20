import SwiftUI

/// Renders a markdown file with executable code blocks.
/// Each fenced code block (```bash, ```sh, ```) gets a "Run" button
/// that sends the code to the terminal session in the same tab.
struct MarkdownRunbookView: View {
    let content: String
    let fileName: String
    let onRunBlock: (String) -> Void
    let onRunAll: () -> Void

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
                    Label("Run", systemImage: "play.fill")
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

        // Regular text
        textAccum += line + "\n"
        i += 1
    }

    flushText()
    return sections
}
