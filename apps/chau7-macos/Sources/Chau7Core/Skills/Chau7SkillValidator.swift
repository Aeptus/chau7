import Foundation

public enum Chau7SkillValidator {
    public static let allowedOptionalDirectoryNames: Set<String> = [
        "scripts",
        "references",
        "assets"
    ]

    public static func validate(
        source: Chau7SkillSource,
        fileManager: FileManager = .default
    ) -> [Chau7SkillValidationIssue] {
        validate(
            rootDirectory: source.rootDirectory,
            fileManager: fileManager
        )
    }

    public static func validate(
        rootDirectory: String,
        fileManager: FileManager = .default
    ) -> [Chau7SkillValidationIssue] {
        let normalizedRoot = rootDirectory.chau7SkillRemovingTrailingSlashes()
        var issues: [Chau7SkillValidationIssue] = []

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: normalizedRoot, isDirectory: &isDirectory) else {
            return [
                issue(
                    code: "missing-folder",
                    message: "Skill folder does not exist.",
                    path: normalizedRoot
                )
            ]
        }

        guard isDirectory.boolValue else {
            return [
                issue(
                    code: "skill-path-not-folder",
                    message: "Skill path must be a folder.",
                    path: normalizedRoot
                )
            ]
        }

        let skillMarkdownPath = "\(normalizedRoot)/SKILL.md"
        guard fileManager.fileExists(atPath: skillMarkdownPath, isDirectory: &isDirectory), !isDirectory.boolValue else {
            issues.append(
                issue(
                    code: "missing-skill-md",
                    message: "SKILL.md is required.",
                    path: skillMarkdownPath
                )
            )
            issues.append(contentsOf: optionalDirectoryIssues(rootDirectory: normalizedRoot, fileManager: fileManager))
            return issues
        }

        let skillMarkdown: String
        do {
            skillMarkdown = try String(contentsOfFile: skillMarkdownPath, encoding: .utf8)
        } catch {
            issues.append(
                issue(
                    code: "unreadable-skill-md",
                    message: "SKILL.md could not be read as UTF-8.",
                    path: skillMarkdownPath
                )
            )
            issues.append(contentsOf: optionalDirectoryIssues(rootDirectory: normalizedRoot, fileManager: fileManager))
            return issues
        }

        switch frontmatter(in: skillMarkdown) {
        case let .parsed(frontmatter):
            issues.append(contentsOf: frontmatterIssues(frontmatter, rootDirectory: normalizedRoot, skillMarkdownPath: skillMarkdownPath))
        case let .issue(frontmatterIssue):
            issues.append(frontmatterIssue.withPath(skillMarkdownPath))
        }

        issues.append(contentsOf: optionalDirectoryIssues(rootDirectory: normalizedRoot, fileManager: fileManager))
        return issues
    }

    public static func isValidSkillName(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard !scalars.isEmpty else { return false }
        guard scalars.first != "-", scalars.last != "-" else { return false }

        var previousWasHyphen = false
        for scalar in scalars {
            switch scalar {
            case "a"..."z", "0"..."9":
                previousWasHyphen = false
            case "-":
                if previousWasHyphen { return false }
                previousWasHyphen = true
            default:
                return false
            }
        }
        return true
    }

    private static func frontmatterIssues(
        _ frontmatter: [String: String],
        rootDirectory: String,
        skillMarkdownPath: String
    ) -> [Chau7SkillValidationIssue] {
        var issues: [Chau7SkillValidationIssue] = []
        let name = frontmatter["name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = frontmatter["description"]?.trimmingCharacters(in: .whitespacesAndNewlines)

        if name == nil || name?.isEmpty == true {
            issues.append(
                issue(
                    code: "missing-name",
                    message: "SKILL.md frontmatter must include a non-empty name.",
                    path: skillMarkdownPath
                )
            )
        } else if let name, !isValidSkillName(name) {
            issues.append(
                issue(
                    code: "invalid-name",
                    message: "Skill name must be lowercase kebab-case.",
                    path: skillMarkdownPath
                )
            )
        }

        if description == nil || description?.isEmpty == true {
            issues.append(
                issue(
                    code: "missing-description",
                    message: "SKILL.md frontmatter must include a non-empty description.",
                    path: skillMarkdownPath
                )
            )
        }

        if let name, isValidSkillName(name) {
            let directoryName = URL(fileURLWithPath: rootDirectory).lastPathComponent
            if directoryName != name {
                issues.append(
                    issue(
                        code: "directory-name-mismatch",
                        message: "Skill folder name must match the SKILL.md frontmatter name.",
                        path: rootDirectory
                    )
                )
            }
        }

        return issues
    }

    private static func optionalDirectoryIssues(
        rootDirectory: String,
        fileManager: FileManager
    ) -> [Chau7SkillValidationIssue] {
        allowedOptionalDirectoryNames.compactMap { directoryName in
            let path = "\(rootDirectory)/\(directoryName)"
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                return nil
            }
            return issue(
                code: "optional-path-not-directory",
                message: "\(directoryName) must be a directory when present.",
                path: path
            )
        }
    }

    private static func frontmatter(in content: String) -> FrontmatterParseResult {
        var lines = content.components(separatedBy: .newlines)
        if let first = lines.first {
            lines[0] = first.trimmingPrefix("\u{feff}")
        }

        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
            return .issue(
                issue(
                    code: "missing-frontmatter",
                    message: "SKILL.md must start with YAML frontmatter."
                )
            )
        }

        var frontmatterLines: [String] = []
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
                return .parsed(parseFrontmatterLines(frontmatterLines))
            }
            frontmatterLines.append(line)
        }

        return .issue(
            issue(
                code: "unterminated-frontmatter",
                message: "SKILL.md YAML frontmatter must end with ---."
            )
        )
    }

    private static func parseFrontmatterLines(_ lines: [String]) -> [String: String] {
        var values: [String: String] = [:]

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let separator = trimmed.firstIndex(of: ":") else { continue }

            let key = String(trimmed[..<separator])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let rawValue = String(trimmed[trimmed.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            values[key] = unquote(rawValue)
        }

        return values
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if value.hasPrefix("\""), value.hasSuffix("\"") {
            return String(value.dropFirst().dropLast())
        }
        if value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func issue(
        code: String,
        message: String,
        path: String? = nil
    ) -> Chau7SkillValidationIssue {
        Chau7SkillValidationIssue(
            severity: .error,
            code: code,
            message: message,
            path: path
        )
    }
}

private enum FrontmatterParseResult {
    case parsed([String: String])
    case issue(Chau7SkillValidationIssue)
}

private extension Chau7SkillValidationIssue {
    func withPath(_ path: String) -> Chau7SkillValidationIssue {
        Chau7SkillValidationIssue(
            severity: severity,
            code: code,
            message: message,
            path: path
        )
    }
}

private extension String {
    func trimmingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }

    func chau7SkillRemovingTrailingSlashes() -> String {
        var value = self
        while value.count > 1, value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }
}
