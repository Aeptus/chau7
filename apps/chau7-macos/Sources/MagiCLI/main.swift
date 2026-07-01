import Chau7Core
import Darwin
import Foundation

enum MagiCLIExitCode: Int32 {
    case success = 0
    case usage = 64
    case unavailable = 69
}

let environment = ProcessInfo.processInfo.environment
let paths = MagiCLIPaths(
    homeDirectory: environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path,
    currentDirectory: FileManager.default.currentDirectoryPath
)
let runner = MagiCLIRunner(paths: paths)
let exitCode = runner.run(arguments: Array(CommandLine.arguments.dropFirst()))
Foundation.exit(exitCode.rawValue)

struct MagiCLIRunner {
    let paths: MagiCLIPaths
    let fileManager: FileManager
    let providerDryRunner: MagiProviderCommandDryRunner

    init(
        paths: MagiCLIPaths,
        fileManager: FileManager = .default,
        providerDryRunner: MagiProviderCommandDryRunner = MagiProviderCommandDryRunner()
    ) {
        self.paths = paths
        self.fileManager = fileManager
        self.providerDryRunner = providerDryRunner
    }

    func run(arguments: [String]) -> MagiCLIExitCode {
        switch MagiCLICommandParser.parse(arguments) {
        case let .success(command):
            return execute(command)
        case let .failure(error):
            FileHandle.standardError.writeLine("MAGI: \(error.localizedDescription)")
            FileHandle.standardError.writeLine(Self.usage)
            return .usage
        }
    }

    private func execute(_ command: MagiCLICommand) -> MagiCLIExitCode {
        switch command {
        case let .ask(question):
            if let exitCode = ensureConfiguredForRun() {
                return exitCode
            }
            return runAsk(question: question)
        case .doctor:
            return runDoctor()
        case .config:
            return runConfig()
        case let .replay(runID):
            return runReplay(runID: runID)
        case let .share(runID):
            return runShare(runID: runID)
        case .help:
            writeStdout(Self.usage)
            return .success
        case .version:
            writeStdout("MAGI CLI phase 9")
            return .success
        }
    }

    private func runAsk(question: String) -> MagiCLIExitCode {
        do {
            let config = try loadConfig()
            let client = MagiMCPClient(socketPath: "\(paths.homeDirectory)/.chau7/mcp.sock")
            try client.connectAndInitialize()

            printHeader()
            let orchestrator = MagiMCPOrchestrator(
                client: client,
                paths: paths,
                fileManager: fileManager,
                isInteractive: isInteractiveTerminal
            )
            _ = try orchestrator.run(question: question, config: config)
            return .success
        } catch {
            FileHandle.standardError.writeLine("MAGI: \(error.localizedDescription)")
            return .unavailable
        }
    }

    private func runReplay(runID: String) -> MagiCLIExitCode {
        let candidates = paths.artifactCandidateBundles(runID: runID, fileManager: fileManager)
        guard let bundle = candidates.first(where: { candidate in
            fileManager.fileExists(atPath: candidate.decisionJSONPath)
                || fileManager.fileExists(atPath: candidate.replayJSONLPath)
        }) else {
            FileHandle.standardError.writeLine("MAGI replay artifact not found for run \(runID).")
            FileHandle.standardError.writeLine("Checked:")
            for candidate in candidates {
                FileHandle.standardError.writeLine("- \(candidate.decisionJSONPath)")
                FileHandle.standardError.writeLine("- \(candidate.replayJSONLPath)")
            }
            return .unavailable
        }

        do {
            let run = try loadRunIfPresent(from: bundle.decisionJSONPath)
            let replayJSONL = try loadStringIfPresent(from: bundle.replayJSONLPath)
            if run == nil, replayJSONL == nil {
                FileHandle.standardError.writeLine("MAGI replay artifact not found for run \(runID).")
                return .unavailable
            }

            printHeader()
            let output = MagiTerminalReplayRenderer.render(run: run, replayJSONL: replayJSONL)
            writeStdout(output, terminator: output.hasSuffix("\n") ? "" : "\n")
            return .success
        } catch {
            FileHandle.standardError.writeLine("MAGI could not replay run \(runID): \(error.localizedDescription)")
            return .unavailable
        }
    }

    private func runShare(runID: String) -> MagiCLIExitCode {
        let candidates = paths.artifactCandidateBundles(runID: runID, fileManager: fileManager)
        if let bundle = candidates.first(where: { fileManager.fileExists(atPath: $0.decisionJSONPath) }) {
            do {
                let run = try loadRun(from: bundle.decisionJSONPath)
                try fileManager.createDirectory(
                    at: URL(fileURLWithPath: bundle.rootDirectory),
                    withIntermediateDirectories: true
                )
                try MagiRunArtifactRenderer.shareHTML(for: run).write(
                    to: URL(fileURLWithPath: bundle.shareHTMLPath),
                    atomically: true,
                    encoding: .utf8
                )

                printHeader()
                writeStdout("Share")
                writeStdout("Run id: \(runID)")
                writeStdout("Generated local share HTML: \(bundle.shareHTMLPath)")
                writeStdout("Hosted upload: disabled in v1")
                return .success
            } catch {
                FileHandle.standardError.writeLine("MAGI could not generate share artifact: \(error.localizedDescription)")
                return .unavailable
            }
        }

        if let bundle = candidates.first(where: { fileManager.fileExists(atPath: $0.shareHTMLPath) }) {
            printHeader()
            writeStdout("Share")
            writeStdout("Run id: \(runID)")
            writeStdout("Existing local share HTML: \(bundle.shareHTMLPath)")
            writeStdout("Hosted upload: disabled in v1")
            return .success
        }

        FileHandle.standardError.writeLine("MAGI share artifact not found for run \(runID).")
        FileHandle.standardError.writeLine("Checked:")
        for candidate in candidates {
            FileHandle.standardError.writeLine("- \(candidate.decisionJSONPath)")
            FileHandle.standardError.writeLine("- \(candidate.shareHTMLPath)")
        }
        return .unavailable
    }

    private func runConfig() -> MagiCLIExitCode {
        printHeader()

        if MagiFirstRunInstaller.isConfigured(paths: paths, fileManager: fileManager) {
            return printConfigSummary()
        }

        guard isInteractiveTerminal else {
            FileHandle.standardError.writeLine("MAGI is not configured. Run `magi config` from an interactive terminal.")
            return .usage
        }

        do {
            _ = try runFirstRunWizard()
            return .success
        } catch {
            FileHandle.standardError.writeLine("MAGI configuration failed: \(error.localizedDescription)")
            return .unavailable
        }
    }

    private func runDoctor() -> MagiCLIExitCode {
        printHeader()
        writeStdout("Doctor")
        writeStdout("Global config: \(paths.globalConfigPath)")
        writeStdout("Personas: \(paths.globalPersonaDirectory)")
        writeStdout("Chau7 MCP socket: \(paths.homeDirectory)/.chau7/mcp.sock")
        writeStdout()

        guard MagiFirstRunInstaller.isConfigured(paths: paths, fileManager: fileManager) else {
            writeStdout("Configuration")
            writeStdout("missing")
            writeStdout()
            writeStdout("Next step")
            writeStdout("Run `magi config` from an interactive terminal.")
            return .success
        }

        do {
            let config = try loadConfig()
            writeStdout("Configuration")
            writeStdout("configured")
            writeStdout()
            printMembers(config)
            printMissingPersonas()
            printDryRunResults(for: selections(from: config))
            return .success
        } catch {
            writeStdout("Configuration")
            writeStdout("invalid: \(error.localizedDescription)")
            return .usage
        }
    }

    private func printConfigSummary() -> MagiCLIExitCode {
        do {
            let config = try loadConfig()
            _ = try MagiFirstRunInstaller.install(
                config: config,
                paths: paths,
                fileManager: fileManager,
                overwrite: false
            )

            writeStdout("Config")
            writeStdout("Global root: \(paths.globalRoot)")
            writeStdout("Global config: \(paths.globalConfigPath)")
            writeStdout("Personas: \(paths.globalPersonaDirectory)")
            writeStdout()
            writeStdout("Status")
            writeStdout("configured")
            writeStdout()
            printMembers(config)
            printMissingPersonas()
            return .success
        } catch {
            writeStdout("Config")
            writeStdout("invalid: \(error.localizedDescription)")
            return .usage
        }
    }

    private func ensureConfiguredForRun() -> MagiCLIExitCode? {
        if MagiFirstRunInstaller.isConfigured(paths: paths, fileManager: fileManager) {
            do {
                _ = try MagiFirstRunInstaller.install(
                    config: loadConfig(),
                    paths: paths,
                    fileManager: fileManager,
                    overwrite: false
                )
            } catch {
                FileHandle.standardError.writeLine("MAGI configuration is invalid: \(error.localizedDescription)")
                return .usage
            }
            return nil
        }

        guard isInteractiveTerminal else {
            FileHandle.standardError.writeLine("MAGI is not configured. Run `magi config` from an interactive terminal.")
            return .usage
        }

        do {
            _ = try runFirstRunWizard()
            return nil
        } catch {
            FileHandle.standardError.writeLine("MAGI configuration failed: \(error.localizedDescription)")
            return .unavailable
        }
    }

    @discardableResult
    private func runFirstRunWizard() throws -> MagiConfig {
        writeStdout("First-run configuration")
        writeStdout("Reasoning defaults to max. You can edit files after setup.")
        writeStdout()

        var selections = promptSelections()
        let dryRunResults = dryRunProviders(for: selections)

        if !dryRunResults.isEmpty {
            writeStdout()
            writeStdout("Provider dry-run")
            printDryRunResults(dryRunResults)
        }

        if let plan = MagiFirstRunPlanner.fallbackPlan(selections: selections, dryRunResults: dryRunResults) {
            writeStdout()
            writeStdout("Fallback duplication")
            let affectedMembers = plan.affectedMembers.map(\.displayName).joined(separator: ", ")
            writeStdout("Members using failed providers: \(affectedMembers)")
            writeStdout("Replacement provider: \(plan.replacementProvider.rawValue)")
            if promptYesNo("Use fallback duplication now?", defaultValue: true) {
                selections = MagiFirstRunPlanner.applyingFallbackDuplication(plan, to: selections)
            }
        } else if !dryRunResults.isEmpty, dryRunResults.allSatisfy({ !$0.passed }) {
            writeStdout()
            writeStdout("No selected provider passed dry-run. MAGI will still write the requested config.")
        }

        let config = MagiFirstRunPlanner.config(from: selections)
        let result = try MagiFirstRunInstaller.install(
            config: config,
            paths: paths,
            fileManager: fileManager,
            overwrite: false
        )

        writeStdout()
        writeStdout("Created")
        if result.createdPaths.isEmpty {
            writeStdout("No new files. Existing files were left untouched.")
        } else {
            for path in result.createdPaths {
                writeStdout("- \(path)")
            }
        }

        if !result.skippedPaths.isEmpty {
            writeStdout()
            writeStdout("Existing files kept")
            for path in result.skippedPaths {
                writeStdout("- \(path)")
            }
        }

        return config
    }

    private func promptSelections() -> [MagiMemberID: MagiFirstRunMemberSelection] {
        var selections = MagiFirstRunPlanner.defaultSelections()

        for memberID in MagiMemberID.allCases {
            let current = selections[memberID] ?? MagiFirstRunMemberSelection(memberID: memberID, provider: .codex)
            writeStdout("\(memberID.displayName)")
            let provider = promptProvider(defaultValue: current.provider)
            let modelClass = promptModelClass(defaultValue: current.modelClass)
            selections[memberID] = MagiFirstRunMemberSelection(
                memberID: memberID,
                provider: provider,
                modelClass: modelClass,
                reasoning: .max
            )
            writeStdout()
        }

        return selections
    }

    private func promptProvider(defaultValue: MagiProviderID) -> MagiProviderID {
        while true {
            let value = prompt("Provider [1 codex, 2 claude, 3 gemini] (default \(defaultValue.rawValue)):")
            if value.isEmpty { return defaultValue }

            switch value.lowercased() {
            case "1", "codex":
                return .codex
            case "2", "claude":
                return .claude
            case "3", "gemini":
                return .gemini
            default:
                writeStdout("Choose codex, claude, or gemini.")
            }
        }
    }

    private func promptModelClass(defaultValue: MagiModelClass) -> MagiModelClass {
        while true {
            let value = prompt("Class [1 fast, 2 balanced, 3 strongest] (default \(defaultValue.rawValue)):")
            if value.isEmpty { return defaultValue }

            switch value.lowercased() {
            case "1", "fast":
                return .fast
            case "2", "balanced":
                return .balanced
            case "3", "strongest":
                return .strongest
            default:
                writeStdout("Choose fast, balanced, or strongest.")
            }
        }
    }

    private func promptYesNo(_ message: String, defaultValue: Bool) -> Bool {
        let defaultLabel = defaultValue ? "Y/n" : "y/N"
        while true {
            let value = prompt("\(message) [\(defaultLabel)]:").lowercased()
            if value.isEmpty { return defaultValue }
            if value == "y" || value == "yes" { return true }
            if value == "n" || value == "no" { return false }
            writeStdout("Choose yes or no.")
        }
    }

    private func prompt(_ message: String) -> String {
        writeStdout(message, terminator: " ")
        fflush(stdout)
        return readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func dryRunProviders(for selections: [MagiMemberID: MagiFirstRunMemberSelection]) -> [MagiProviderDryRunResult] {
        let selectedProviders = Set(selections.values.map(\.provider))
        return MagiProviderID.allCases
            .filter { selectedProviders.contains($0) }
            .map { providerDryRunner.run(provider: $0) }
    }

    private func printDryRunResults(for selections: [MagiMemberID: MagiFirstRunMemberSelection]) {
        let results = dryRunProviders(for: selections)
        guard !results.isEmpty else { return }

        writeStdout()
        writeStdout("Provider dry-run")
        printDryRunResults(results)
    }

    private func printDryRunResults(_ results: [MagiProviderDryRunResult]) {
        for result in results {
            let status = result.passed ? "ok" : "failed"
            if result.detail.isEmpty {
                writeStdout("- \(result.provider.rawValue): \(status)")
            } else {
                writeStdout("- \(result.provider.rawValue): \(status) - \(result.detail)")
            }
        }
    }

    private func printMembers(_ config: MagiConfig) {
        writeStdout("Members")
        for memberID in MagiMemberID.allCases {
            let member = config.members[memberID] ?? MagiMemberConfiguration(provider: "unconfigured")
            writeStdout("- \(memberID.displayName): provider=\(member.provider), class=\(member.modelClass.rawValue), reasoning=\(member.reasoning.rawValue)")
        }
    }

    private func printMissingPersonas() {
        let missing = MagiFirstRunInstaller.missingPersonaFiles(paths: paths, fileManager: fileManager)
        writeStdout()
        writeStdout("Persona files")
        if missing.isEmpty {
            writeStdout("present")
        } else {
            let missingNames = missing.map(\.rawValue).joined(separator: ", ")
            writeStdout("missing: \(missingNames)")
        }
    }

    private func loadConfig() throws -> MagiConfig {
        let content = try String(contentsOfFile: paths.globalConfigPath, encoding: .utf8)
        return try MagiConfigTOMLCodec.decode(content)
    }

    private func loadRunIfPresent(from path: String) throws -> MagiRun? {
        guard fileManager.fileExists(atPath: path) else { return nil }
        return try loadRun(from: path)
    }

    private func loadRun(from path: String) throws -> MagiRun {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MagiRun.self, from: data)
    }

    private func loadStringIfPresent(from path: String) throws -> String? {
        guard fileManager.fileExists(atPath: path) else { return nil }
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    private func selections(from config: MagiConfig) -> [MagiMemberID: MagiFirstRunMemberSelection] {
        MagiMemberID.allCases.reduce(into: [MagiMemberID: MagiFirstRunMemberSelection]()) { result, memberID in
            guard let member = config.members[memberID],
                  let provider = MagiProviderID(rawValue: member.provider)
            else {
                return
            }
            result[memberID] = MagiFirstRunMemberSelection(
                memberID: memberID,
                provider: provider,
                modelClass: member.modelClass,
                reasoning: member.reasoning
            )
        }
    }

    private var isInteractiveTerminal: Bool {
        isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
    }

    private func writeStdout(_ line: String = "", terminator: String = "\n") {
        FileHandle.standardOutput.writeText("\(line)\(terminator)")
    }

    private func printHeader() {
        writeStdout("MAGI")
        writeStdout("Multi Agent Gathering Intelligence")
        writeStdout()
    }

    static let usage = """
    MAGI - Multi Agent Gathering Intelligence

    Usage:
      magi "question"
      magi ask "question"
      magi doctor
      magi config
      magi replay <run-id>
      magi share <run-id>

    First run:
      magi config

    MAGI is also supported as a command name on supported installations.
    """
}

struct MagiProviderCommandDryRunner {
    var timeoutSeconds: TimeInterval = 5

    func run(provider: MagiProviderID) -> MagiProviderDryRunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [provider.rawValue, "--version"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return MagiProviderDryRunResult(provider: provider, passed: false, detail: error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            return MagiProviderDryRunResult(provider: provider, passed: false, detail: "timed out")
        }

        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus == 0 {
            return MagiProviderDryRunResult(provider: provider, passed: true, detail: firstLine(output))
        }

        let detail = firstLine(output).isEmpty ? "exit \(process.terminationStatus)" : firstLine(output)
        return MagiProviderDryRunResult(provider: provider, passed: false, detail: detail)
    }

    private func firstLine(_ output: String) -> String {
        output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }
}

extension FileHandle {
    func writeText(_ text: String) {
        if let data = text.data(using: .utf8) {
            write(data)
        }
    }

    func writeLine(_ line: String) {
        writeText("\(line)\n")
    }
}
