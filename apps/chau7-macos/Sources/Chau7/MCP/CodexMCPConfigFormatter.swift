import Foundation

enum CodexMCPConfigFormatter {
    static func upsertChau7Server(in content: String, command: String) -> String {
        if containsChau7ServerSection(in: content) {
            return rewriteExistingChau7Section(in: content, command: command)
        }

        let section = """
        \n[mcp_servers.chau7]
        command = "\(tomlString(command))"
        args = []
        """
        var updated = content
        if let range = updated.range(of: "\n[features]") {
            updated.insert(contentsOf: section + "\n", at: range.lowerBound)
        } else {
            updated += section + "\n"
        }
        return updated
    }

    private static func rewriteExistingChau7Section(in content: String, command: String) -> String {
        let lines = content.components(separatedBy: "\n")
        var updated: [String] = []
        var inChau7Section = false
        var skippingArgsContinuation = false
        var commandUpdated = false
        var argsUpdated = false

        func flushMissingFields() {
            if !commandUpdated {
                updated.append("command = \"\(tomlString(command))\"")
                commandUpdated = true
            }
            if !argsUpdated {
                updated.append("args = []")
                argsUpdated = true
            }
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if skippingArgsContinuation {
                if trimmed.hasPrefix("[") {
                    skippingArgsContinuation = false
                } else {
                    if trimmed.contains("]") {
                        skippingArgsContinuation = false
                    }
                    continue
                }
            }

            if trimmed == "[mcp_servers.chau7]" {
                inChau7Section = true
                commandUpdated = false
                argsUpdated = false
                updated.append(line)
            } else if inChau7Section, trimmed.hasPrefix("[") {
                flushMissingFields()
                inChau7Section = false
                updated.append(line)
            } else if inChau7Section, isAssignment(trimmed, named: "command") {
                updated.append("command = \"\(tomlString(command))\"")
                commandUpdated = true
            } else if inChau7Section, isAssignment(trimmed, named: "args") {
                updated.append("args = []")
                argsUpdated = true
                skippingArgsContinuation = startsMultilineArray(trimmed)
            } else {
                updated.append(line)
            }
        }

        if inChau7Section {
            flushMissingFields()
        }

        return updated.joined(separator: "\n")
    }

    private static func isAssignment(_ trimmedLine: String, named key: String) -> Bool {
        trimmedLine.hasPrefix("\(key) ") || trimmedLine.hasPrefix("\(key)=")
    }

    private static func containsChau7ServerSection(in content: String) -> Bool {
        content
            .components(separatedBy: "\n")
            .contains { $0.trimmingCharacters(in: .whitespaces) == "[mcp_servers.chau7]" }
    }

    private static func startsMultilineArray(_ trimmedLine: String) -> Bool {
        guard let equalsIndex = trimmedLine.firstIndex(of: "=") else { return false }
        let value = trimmedLine[trimmedLine.index(after: equalsIndex)...]
            .trimmingCharacters(in: .whitespaces)
        return value.hasPrefix("[") && !value.contains("]")
    }

    private static func tomlString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
