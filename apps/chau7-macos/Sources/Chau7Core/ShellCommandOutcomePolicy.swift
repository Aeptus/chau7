import Foundation

/// Classifies shell commands whose completion is useful enough to surface by
/// default. Exit status remains authoritative; this policy only controls
/// whether Chau7 turns that status into user-facing script attention.
public enum ShellCommandOutcomePolicy {
    public enum CommandKind: Equatable, Sendable {
        case ordinary
        case script
        case devServer
    }

    public enum CompletionDisposition: Equatable, Sendable {
        case ordinary
        case scriptSucceeded
        case scriptFailed
        case devServerFailed
        case suppress
    }

    private static let scriptExtensions: Set<String> = [
        "bash", "cjs", "fish", "js", "mjs", "py", "rb", "sh", "swift", "ts", "zsh"
    ]

    private static let directTaskRunners: Set<String> = [
        "gradle", "gradlew", "just", "make", "mvn", "mvnw", "nox", "pytest", "rake", "task", "tox", "xcodebuild"
    ]

    private static let packageManagerBuiltins: Set<String> = [
        "add", "audit", "bin", "cache", "config", "create", "dlx", "doctor", "env", "exec", "fetch",
        "help", "import", "info", "init", "install", "licenses", "link", "list", "login", "logout",
        "outdated", "owner", "pack", "patch", "prune", "publish", "rebuild", "remove", "root", "search",
        "setup", "store", "tag", "team", "uninstall", "update", "version", "view", "whoami", "why",
        "workspace", "workspaces"
    ]

    private static let buildToolSubcommands: [String: Set<String>] = [
        "cargo": ["bench", "build", "check", "clippy", "doc", "fmt", "run", "test"],
        "dotnet": ["build", "format", "publish", "run", "test"],
        "go": ["build", "generate", "run", "test", "vet"],
        "swift": ["build", "run", "test"]
    ]

    /// Returns the noteworthy lifecycle class for a command line.
    public static func classify(_ commandLine: String?) -> CommandKind {
        guard let commandLine,
              !commandLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .ordinary
        }

        if CommandDetection.detectDevServer(from: commandLine) != nil {
            return .devServer
        }

        let tokens = CommandDetection.tokenize(commandLine)
        guard let commandIndex = CommandDetection.commandTokenIndex(from: tokens) else {
            return .ordinary
        }

        let rawCommand = tokens[commandIndex]
        let command = URL(fileURLWithPath: rawCommand).lastPathComponent.lowercased()
        let arguments = Array(tokens.dropFirst(commandIndex + 1))

        if isScriptPath(rawCommand) || directTaskRunners.contains(command) {
            return .script
        }

        if let acceptedSubcommands = buildToolSubcommands[command],
           let subcommand = firstPositionalArgument(in: arguments),
           acceptedSubcommands.contains(subcommand) {
            return .script
        }

        switch command {
        case "npm":
            return isNPMScript(arguments) ? .script : .ordinary
        case "pnpm", "yarn", "bun":
            return isPackageManagerScript(arguments) ? .script : .ordinary
        case "npx", "bunx":
            return firstPositionalArgument(in: arguments) == nil ? .ordinary : .script
        case "deno":
            return firstPositionalArgument(in: arguments) == "task" ? .script : .ordinary
        case "bash", "fish", "sh", "zsh":
            return isShellScriptInvocation(arguments) ? .script : .ordinary
        case "node", "python", "python3", "ruby", "swift":
            return isInterpreterScriptInvocation(arguments, command: command) ? .script : .ordinary
        default:
            return .ordinary
        }
    }

    /// Converts an authoritative shell exit into the default-notice decision.
    /// A nil status is heuristic and therefore cannot establish success.
    public static func completionDisposition(
        commandLine: String?,
        exitCode: Int?
    ) -> CompletionDisposition {
        switch classify(commandLine) {
        case .ordinary:
            return .ordinary
        case .script:
            guard let exitCode else { return .suppress }
            return exitCode == 0 ? .scriptSucceeded : .scriptFailed
        case .devServer:
            guard let exitCode else { return .suppress }
            return devServerExitIsFailure(exitCode) ? .devServerFailed : .suppress
        }
    }

    /// Interrupt-style exits are normal for long-running dev servers.
    public static func devServerExitIsFailure(_ exitCode: Int) -> Bool {
        exitCode != 0 && exitCode != 130 && exitCode != 143
    }

    private static func isScriptPath(_ command: String) -> Bool {
        let path = command.lowercased()
        if path.hasPrefix("./") || path.hasPrefix("../") {
            return true
        }
        return scriptExtensions.contains(URL(fileURLWithPath: path).pathExtension)
    }

    private static func isNPMScript(_ arguments: [String]) -> Bool {
        let positional = positionalArguments(in: arguments)
        guard let first = positional.first else { return false }
        if first == "run" {
            return positional.count >= 2
        }
        return ["restart", "start", "stop", "test"].contains(first)
    }

    private static func isPackageManagerScript(_ arguments: [String]) -> Bool {
        let positional = positionalArguments(in: arguments)
        guard let first = positional.first else { return false }
        if first == "run" {
            return positional.count >= 2
        }
        return !packageManagerBuiltins.contains(first)
    }

    private static func isShellScriptInvocation(_ arguments: [String]) -> Bool {
        guard !arguments.contains("-c"), let operand = firstPositionalArgument(in: arguments) else {
            return false
        }
        return operand != "-"
    }

    private static func isInterpreterScriptInvocation(_ arguments: [String], command: String) -> Bool {
        guard !arguments.contains("-c") else { return false }

        if let moduleIndex = arguments.firstIndex(of: "-m"), moduleIndex + 1 < arguments.count {
            let module = arguments[moduleIndex + 1].lowercased()
            return command.hasPrefix("python") && ["build", "mypy", "pytest", "ruff", "unittest"].contains(module)
        }

        guard let operand = firstPositionalArgument(in: arguments) else { return false }
        return isScriptPath(operand)
    }

    private static func firstPositionalArgument(in arguments: [String]) -> String? {
        positionalArguments(in: arguments).first
    }

    private static func positionalArguments(in arguments: [String]) -> [String] {
        arguments
            .filter { !$0.hasPrefix("-") }
            .map { $0.lowercased() }
    }
}
