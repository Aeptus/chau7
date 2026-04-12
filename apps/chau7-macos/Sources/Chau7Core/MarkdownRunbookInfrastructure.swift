import Foundation

public enum MarkdownSectionKind: Equatable, Sendable {
    case heading(level: Int, text: String)
    case text(String)
    case codeBlock(language: String?, code: String, lineNumber: Int)
    case checkboxItem(checked: Bool, text: String, lineNumber: Int)
    case bulletItem(text: String, lineNumber: Int)
    case numberedItem(number: Int, text: String, lineNumber: Int)
    case horizontalRule(lineNumber: Int)
}

public struct MarkdownSection: Equatable, Sendable {
    public let kind: MarkdownSectionKind

    public init(kind: MarkdownSectionKind) {
        self.kind = kind
    }
}

public struct PlanProgress: Equatable, Sendable {
    public let checked: Int
    public let total: Int

    public init(checked: Int, total: Int) {
        self.checked = checked
        self.total = total
    }

    public var percentage: Float {
        guard total > 0 else { return 0 }
        return (Float(checked) / Float(total)) * 100
    }

    public var summaryText: String {
        "\(checked)/\(total)"
    }
}

public enum CompanionPlanLocator {
    public static let repoScopedRelativePath = ".chau7/plan.md"

    private static let knownPlanNames: Set = [
        "plan.md", "todo.md", "plan.markdown", "todo.markdown",
        "PLAN.md", "TODO.md", "PLAN.markdown", "TODO.markdown"
    ]

    public static func repositoryPlanPath(repoRoot: String) -> String {
        URL(fileURLWithPath: repoRoot)
            .appendingPathComponent(repoScopedRelativePath)
            .path
    }

    public static func sessionPlanPath(repoRoot: String, sessionID: String) -> String {
        URL(fileURLWithPath: repoRoot)
            .appendingPathComponent(".chau7/sessions/\(sessionID)/plan.md")
            .path
    }

    public static func shouldSurfacePlanFile(relativePath: String) -> Bool {
        let normalized = relativePath.replacingOccurrences(of: "\\", with: "/")
        let lowercased = normalized.lowercased()
        if lowercased == ".chau7/plan.md" {
            return true
        }
        if lowercased.hasPrefix(".chau7/sessions/"), lowercased.hasSuffix("/plan.md") {
            return true
        }
        if normalized.contains("/") {
            return false
        }
        return knownPlanNames.contains(normalized) || knownPlanNames.contains(lowercased)
    }

    public static func detectedPlanCandidates(from touchedFiles: Set<String>) -> [String] {
        touchedFiles
            .filter(shouldSurfacePlanFile(relativePath:))
            .sorted()
    }

    public static func preferredPlanPath(repoRoot: String, touchedFiles: Set<String>, sessionIDs: [String] = []) -> String {
        let repoURL = URL(fileURLWithPath: repoRoot)
        if sessionIDs.count == 1, let sessionID = sessionIDs.first {
            let sessionPlan = sessionPlanPath(repoRoot: repoRoot, sessionID: sessionID)
            if FileManager.default.fileExists(atPath: sessionPlan) {
                return sessionPlan
            }
            return sessionPlan
        }
        for relativePath in detectedPlanCandidates(from: touchedFiles) {
            let candidate = repoURL.appendingPathComponent(relativePath).path
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        let repoScoped = repositoryPlanPath(repoRoot: repoRoot)
        if FileManager.default.fileExists(atPath: repoScoped) {
            return repoScoped
        }
        return repoScoped
    }

    public static func defaultSkeleton(repoName: String? = nil) -> String {
        let title: String
        if let repoName, !repoName.isEmpty {
            title = "# \(repoName) Runbook"
        } else {
            title = "# Session Runbook"
        }
        return [
            title,
            "",
            "## Goals",
            "- [ ] Clarify the objective",
            "- [ ] Confirm scope and risks",
            "",
            "## Tasks",
            "- [ ] Implement the next change",
            "- [ ] Verify with build and tests",
            "",
            "## Notes",
            "- Capture blockers, follow-ups, or handoff context here.",
            ""
        ].joined(separator: "\n")
    }
}

public func parseMarkdown(_ input: String) -> [MarkdownSection] {
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

        if line.hasPrefix("```") {
            flushText()
            let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            var codeLines: [String] = []
            i += 1
            while i < lines.count, !lines[i].hasPrefix("```") {
                codeLines.append(lines[i])
                i += 1
            }
            let code = codeLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !code.isEmpty {
                sections.append(MarkdownSection(kind: .codeBlock(language: lang.isEmpty ? nil : lang, code: code, lineNumber: i)))
            }
            if i < lines.count { i += 1 }
            continue
        }

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

        if isHorizontalRule(line) {
            flushText()
            sections.append(MarkdownSection(kind: .horizontalRule(lineNumber: i)))
            i += 1
            continue
        }

        if let match = parseCheckboxLine(line) {
            flushText()
            sections.append(MarkdownSection(kind: .checkboxItem(checked: match.checked, text: match.text, lineNumber: i)))
            i += 1
            continue
        }

        if let bulletText = parseBulletLine(line) {
            flushText()
            sections.append(MarkdownSection(kind: .bulletItem(text: bulletText, lineNumber: i)))
            i += 1
            continue
        }

        if let numbered = parseNumberedLine(line) {
            flushText()
            sections.append(MarkdownSection(kind: .numberedItem(number: numbered.number, text: numbered.text, lineNumber: i)))
            i += 1
            continue
        }

        textAccum += line + "\n"
        i += 1
    }

    flushText()
    return sections
}

public func computePlanProgress(from content: String) -> PlanProgress {
    let sections = parseMarkdown(content)
    let checkboxStates = sections.compactMap { section -> Bool? in
        guard case let .checkboxItem(checked, _, _) = section.kind else { return nil }
        return checked
    }
    return PlanProgress(checked: checkboxStates.filter { $0 }.count, total: checkboxStates.count)
}

public func toggleCheckboxInContent(_ content: String, lineNumber: Int) -> String {
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

private func parseCheckboxLine(_ line: String) -> (checked: Bool, text: String)? {
    let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
    guard let first = trimmed.first, first == "-" || first == "*" else { return nil }
    let afterBullet = trimmed.dropFirst()
    guard afterBullet.hasPrefix(" [") else { return nil }
    let afterBracket = afterBullet.dropFirst(2)
    guard let marker = afterBracket.first else { return nil }
    let checked: Bool
    switch marker {
    case "x", "X": checked = true
    case " ": checked = false
    default: return nil
    }
    let rest = afterBracket.dropFirst()
    guard rest.hasPrefix("] ") else { return nil }
    let text = String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    return text.isEmpty ? nil : (checked, text)
}

private func parseBulletLine(_ line: String) -> String? {
    let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
    guard let first = trimmed.first, first == "-" || first == "*" else { return nil }
    let text = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty, !text.hasPrefix("[") else { return nil }
    return text
}

private func parseNumberedLine(_ line: String) -> (number: Int, text: String)? {
    let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
    let scalars = Array(trimmed)
    var digits = ""
    var index = 0
    while index < scalars.count, scalars[index].isNumber {
        digits.append(scalars[index])
        index += 1
    }
    guard !digits.isEmpty, index < scalars.count, scalars[index] == "." else { return nil }
    index += 1
    guard index < scalars.count, scalars[index] == " " else { return nil }
    let text = String(scalars[(index + 1)...]).trimmingCharacters(in: .whitespaces)
    guard let number = Int(digits), !text.isEmpty else { return nil }
    return (number, text)
}

private func isHorizontalRule(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.count >= 3 else { return false }
    return Set(trimmed).count == 1 && trimmed.first == "-"
}
