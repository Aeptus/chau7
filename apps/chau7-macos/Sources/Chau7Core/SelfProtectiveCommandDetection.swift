import Foundation

public struct SelfProtectiveCommandContext: Sendable {
    public let protectedPIDs: Set<Int32>
    public let protectedProcessNames: Set<String>

    public init(
        protectedPIDs: Set<Int32> = [],
        protectedProcessNames: Set<String> = []
    ) {
        self.protectedPIDs = protectedPIDs
        self.protectedProcessNames = Set(
            protectedProcessNames
                .map(SelfProtectiveCommandDetection.normalizeToken(_:))
                .filter { !$0.isEmpty }
        )
    }
}

public enum SelfProtectiveCommandDetection {
    public struct Match: Equatable, Sendable {
        public let command: String
        public let reason: String

        public init(command: String, reason: String) {
            self.command = command
            self.reason = reason
        }
    }

    public static func detect(commandLine: String, context: SelfProtectiveCommandContext) -> Match? {
        let trimmed = commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        for subcommand in splitSubcommands(trimmed) {
            if let match = detect(in: subcommand, context: context) {
                return match
            }
        }

        return nil
    }

    private static func detect(in command: String, context: SelfProtectiveCommandContext) -> Match? {
        let tokens = tokenize(command)
        guard let rawExecutable = tokens.first else { return nil }

        let executable = normalizeToken(rawExecutable)
        switch executable {
        case "kill":
            if hasProtectedKillTarget(tokens: Array(tokens.dropFirst()), context: context) {
                return Match(
                    command: command,
                    reason: "would terminate a protected Chau7-managed process"
                )
            }
        case "pkill", "killall":
            if hasProtectedProcessPattern(tokens: Array(tokens.dropFirst()), context: context) {
                return Match(
                    command: command,
                    reason: "would target Chau7 or a protected Chau7 helper process"
                )
            }
        case "osascript":
            if isQuittingProtectedApp(command, context: context) {
                return Match(
                    command: command,
                    reason: "would ask macOS to quit Chau7"
                )
            }
        default:
            break
        }

        return nil
    }

    private static func hasProtectedKillTarget(tokens: [String], context: SelfProtectiveCommandContext) -> Bool {
        var expectSignalValue = false
        var parseTargetsOnly = false

        for token in tokens {
            let normalized = normalizeToken(token)
            if normalized.isEmpty { continue }

            if expectSignalValue {
                expectSignalValue = false
                continue
            }

            if normalized == "--" {
                parseTargetsOnly = true
                continue
            }

            if normalized == "-s" || normalized == "--signal" {
                expectSignalValue = true
                continue
            }

            if !parseTargetsOnly, normalized.hasPrefix("-"), !looksLikeProcessGroupTarget(normalized, context: context) {
                continue
            }

            if matchesProtectedPID(normalized, context: context) {
                return true
            }
        }

        return false
    }

    private static func hasProtectedProcessPattern(tokens: [String], context: SelfProtectiveCommandContext) -> Bool {
        for token in tokens {
            let normalized = normalizeToken(token)
            if normalized.isEmpty || normalized.hasPrefix("-") {
                continue
            }

            if context.protectedProcessNames.contains(where: { normalized.contains($0) || $0.contains(normalized) }) {
                return true
            }
        }

        return false
    }

    private static func isQuittingProtectedApp(_ command: String, context: SelfProtectiveCommandContext) -> Bool {
        let normalized = normalizeCommand(command)
        guard normalized.contains("quit app") else { return false }
        return context.protectedProcessNames.contains(where: { normalized.contains($0) })
    }

    private static func matchesProtectedPID(_ token: String, context: SelfProtectiveCommandContext) -> Bool {
        if token == "$$" || token == "-$$" {
            return !context.protectedPIDs.isEmpty
        }

        let signless: String
        if token.hasPrefix("-") {
            signless = String(token.dropFirst())
        } else {
            signless = token
        }

        guard let value = Int32(signless) else { return false }
        return context.protectedPIDs.contains(value)
    }

    private static func looksLikeProcessGroupTarget(_ token: String, context: SelfProtectiveCommandContext) -> Bool {
        guard token.hasPrefix("-") else { return false }
        let target = String(token.dropFirst())
        guard let value = Int32(target) else { return false }
        return context.protectedPIDs.contains(value)
    }

    private static func splitSubcommands(_ command: String) -> [String] {
        var commands: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var escape = false
        var index = command.startIndex

        while index < command.endIndex {
            let character = command[index]

            if escape {
                current.append(character)
                escape = false
                index = command.index(after: index)
                continue
            }

            if character == "\\", !inSingle {
                escape = true
                current.append(character)
                index = command.index(after: index)
                continue
            }

            if character == "'", !inDouble {
                inSingle.toggle()
                current.append(character)
                index = command.index(after: index)
                continue
            }

            if character == "\"", !inSingle {
                inDouble.toggle()
                current.append(character)
                index = command.index(after: index)
                continue
            }

            if !inSingle, !inDouble {
                let remaining = command[index...]
                if remaining.hasPrefix("&&") || remaining.hasPrefix("||") {
                    appendSubcommand(current, to: &commands)
                    current = ""
                    index = command.index(index, offsetBy: 2)
                    continue
                }

                if character == ";" || character == "|" || character == "&" || character == "\n" || character == "\r" {
                    appendSubcommand(current, to: &commands)
                    current = ""
                    index = command.index(after: index)
                    continue
                }
            }

            current.append(character)
            index = command.index(after: index)
        }

        appendSubcommand(current, to: &commands)
        return commands
    }

    private static func appendSubcommand(_ value: String, to commands: inout [String]) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        commands.append(trimmed)
    }

    private static func tokenize(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var escape = false

        for character in command {
            if escape {
                current.append(character)
                escape = false
                continue
            }

            if character == "\\", !inSingle {
                escape = true
                continue
            }

            if character == "'", !inDouble {
                inSingle.toggle()
                continue
            }

            if character == "\"", !inSingle {
                inDouble.toggle()
                continue
            }

            if !inSingle, !inDouble, character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }

            current.append(character)
        }

        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }

    private static func normalizeCommand(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    public static func normalizeToken(_ value: String) -> String {
        value
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
