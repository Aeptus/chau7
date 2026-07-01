import Chau7Core
import Darwin
import Foundation

enum MagiCLIExitCode: Int32 {
    case success = 0
    case usage = 64
    case unavailable = 69
}

let environment = ProcessInfo.processInfo.environment

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
        case .home:
            return runHome()
        case let .replay(runID):
            return runReplay(runID: runID)
        case let .share(runID):
            return runShare(runID: runID)
        case .help:
            writeStdout(Self.usage)
            return .success
        case .version:
            writeStdout("MAGI CLI phase 10")
            return .success
        }
    }

    private func runAsk(question: String) -> MagiCLIExitCode {
        do {
            let config = try loadConfig()
            let client = MagiMCPClient(socketPath: "\(paths.homeDirectory)/.chau7/mcp.sock")
            do {
                try client.connectAndInitialize()
            } catch {
                let bundle = writePreflightFailureArtifact(
                    question: question,
                    config: config,
                    error: error,
                    category: preflightFailureCategory(for: error)
                )
                FileHandle.standardError.writeLine("MAGI: \(error.localizedDescription)")
                if let bundle {
                    FileHandle.standardError.writeLine("MAGI failed run artifacts: \(bundle.rootDirectory)")
                }
                return .unavailable
            }

            let interruptFlag = MagiInterruptFlag.shared
            interruptFlag.install()
            printHeader()
            let orchestrator = MagiMCPOrchestrator(
                client: client,
                paths: paths,
                fileManager: fileManager,
                isInteractive: isInteractiveTerminal,
                isInterrupted: { interruptFlag.isInterrupted }
            )
            _ = try orchestrator.run(question: question, config: config)
            return .success
        } catch {
            FileHandle.standardError.writeLine("MAGI: \(error.localizedDescription)")
            return .unavailable
        }
    }

    private func runHome() -> MagiCLIExitCode {
        guard isInteractiveTerminal else {
            writeStdout(Self.usage)
            return .success
        }

        printHomeScreen()

        while true {
            let input = prompt("MAGI>")
            let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }

            switch value.lowercased() {
            case "q", "quit", "exit":
                writeMuted("MAGI system standing by.")
                return .success
            case "help", "?":
                printHomeHelp()
            case "--config", "config":
                let code = runConfigPanel()
                if code != .success { return code }
                writeStdout()
                writeMuted("Ask a question, type --config, doctor, help, or quit.")
            case "doctor":
                writeStdout()
                _ = runDoctor()
                writeStdout()
                writeMuted("Ask a question, type --config, doctor, help, or quit.")
            default:
                if let exitCode = ensureConfiguredForRun() {
                    return exitCode
                }
                return runAsk(question: value)
            }
        }
    }

    private func printHomeScreen() {
        let art = """
        __  __    _    ____ ___
        |  \\/  |  / \\  / ___|_ _|
        | |\\/| | / _ \\| |  _ | |
        | |  | |/ ___ \\ |_| || |
        |_|  |_/_/   \\_\\____|___|
        """
        writeStdout(styled(art, .bold, .cyan))
        writeStdout(styled("WELCOME TO MAGI SYSTEM", .bold))
        writeStdout()
        printBootLine("core protocol", "Multi Agent Gathering Intelligence online")
        printBootLine("council", "Melchior / Balthasar / Casper registered")
        let socketPath = "\(paths.homeDirectory)/.chau7/mcp.sock"
        let socketPresent = fileManager.fileExists(atPath: socketPath)
        let socketDetail = socketPresent ? "Chau7 MCP socket present" : "Chau7 MCP socket missing"
        printBootLine("mcp", socketDetail, ok: socketPresent)
        let configPresent = MagiFirstRunInstaller.isConfigured(paths: paths, fileManager: fileManager)
        let configDetail = configPresent
            ? "config loaded"
            : "config missing; type --config"
        printBootLine("config", configDetail, ok: configPresent)
        printBootLine("mood", "serious council, questionable coffee")
        writeStdout()
        writeMuted("Ask a question, type --config, doctor, help, or quit.")
    }

    private func printBootLine(_ label: String, _ detail: String, ok: Bool = true) {
        let status = ok ? styled("[ OK ]", .green) : styled("[ .. ]", .yellow)
        writeStdout("\(status) \(label.padding(toLength: 14, withPad: " ", startingAt: 0)) \(detail)")
    }

    private func printHomeHelp() {
        writeStdout()
        writeWizardSection("Home commands")
        writeStdout("Type any question to ask the council.")
        writeStdout("--config  Open the configuration panel.")
        writeStdout("doctor    Check config, personas, MCP socket, and providers.")
        writeStdout("quit      Exit MAGI.")
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
            var run: MagiRun?
            do {
                run = try loadRunIfPresent(from: bundle.decisionJSONPath)
            } catch {
                FileHandle.standardError.writeLine("MAGI warning: decision.json is unreadable; falling back to replay.jsonl if present. \(error.localizedDescription)")
                run = nil
            }
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
                if fileManager.fileExists(atPath: bundle.shareHTMLPath) {
                    FileHandle.standardError.writeLine("MAGI warning: decision.json is unreadable; using existing share.html. \(error.localizedDescription)")
                    return printExistingShare(runID: runID, bundle: bundle)
                }
                FileHandle.standardError.writeLine("MAGI could not generate share artifact: \(error.localizedDescription)")
                return .unavailable
            }
        }

        if let bundle = candidates.first(where: { fileManager.fileExists(atPath: $0.shareHTMLPath) }) {
            return printExistingShare(runID: runID, bundle: bundle)
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
            guard isInteractiveTerminal else {
                return printConfigSummary()
            }
            return runConfigPanel()
        }

        guard isInteractiveTerminal else {
            FileHandle.standardError.writeLine(nonInteractiveConfigMessage)
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

    private func runConfigPanel() -> MagiCLIExitCode {
        guard isInteractiveTerminal else {
            return printConfigSummary()
        }

        guard MagiFirstRunInstaller.isConfigured(paths: paths, fileManager: fileManager) else {
            do {
                _ = try runFirstRunWizard()
                return .success
            } catch {
                FileHandle.standardError.writeLine("MAGI configuration failed: \(error.localizedDescription)")
                return .unavailable
            }
        }

        do {
            var config = try loadConfig()
            _ = try MagiFirstRunInstaller.install(
                config: config,
                paths: paths,
                fileManager: fileManager,
                overwrite: false
            )

            while true {
                printConfigPanel(config)
                let choice = prompt("Config>").lowercased()

                switch choice {
                case "", "q", "quit", "exit", "back":
                    writeMuted("Configuration panel closed.")
                    return .success
                case "1", "all":
                    writeWizardSection("Apply to all members")
                    let provider = promptProvider(defaultValue: .codex)
                    let modelClass = promptModelClass(defaultValue: .balanced)
                    for memberID in MagiMemberID.allCases {
                        config.members[memberID] = MagiMemberConfiguration(
                            provider: provider.rawValue,
                            modelClass: modelClass,
                            reasoning: .max
                        )
                    }
                    try saveConfig(config)
                    writeSaved()
                case "2", "member":
                    guard let memberID = promptMemberID() else { continue }
                    let current = config.members[memberID] ?? MagiMemberConfiguration(provider: "codex")
                    writeWizardSection(memberID.displayName)
                    let defaultProvider = MagiProviderID(rawValue: current.provider) ?? .codex
                    let provider = promptProvider(defaultValue: defaultProvider)
                    let modelClass = promptModelClass(defaultValue: current.modelClass)
                    config.members[memberID] = MagiMemberConfiguration(
                        provider: provider.rawValue,
                        modelClass: modelClass,
                        reasoning: current.reasoning,
                        modelName: current.modelName
                    )
                    try saveConfig(config)
                    writeSaved()
                case "3", "web":
                    config.webAccessAllowed.toggle()
                    try saveConfig(config)
                    writeSaved()
                case "4", "evidence":
                    config.evidenceRequiresApproval.toggle()
                    try saveConfig(config)
                    writeSaved()
                case "5", "deadlock":
                    config.deadlockExtraRoundEnabled.toggle()
                    try saveConfig(config)
                    writeSaved()
                case "6", "veto":
                    config.vetoBlocksVerdict.toggle()
                    try saveConfig(config)
                    writeSaved()
                case "7", "doctor":
                    writeStdout()
                    _ = runDoctor()
                case "8", "personas":
                    _ = try MagiFirstRunInstaller.install(
                        config: config,
                        paths: paths,
                        fileManager: fileManager,
                        overwrite: false
                    )
                    writeSaved("Persona files checked.")
                case "help", "?":
                    continue
                default:
                    writeStdout("Choose 1-8, all, member, web, evidence, deadlock, veto, doctor, personas, or quit.")
                }
            }
        } catch {
            FileHandle.standardError.writeLine("MAGI configuration failed: \(error.localizedDescription)")
            return .unavailable
        }
    }

    private func printConfigPanel(_ config: MagiConfig) {
        writeStdout()
        writeWizardTitle("Configuration panel")
        writeMuted(paths.globalConfigPath)
        writeStdout()
        printMembers(config)
        writeStdout()
        writeStdout("Settings")
        writeStdout("- web_access_allowed: \(boolLabel(config.webAccessAllowed))")
        writeStdout("- evidence_requires_approval: \(boolLabel(config.evidenceRequiresApproval))")
        writeStdout("- deadlock_extra_round_enabled: \(boolLabel(config.deadlockExtraRoundEnabled))")
        writeStdout("- veto_blocks_verdict: \(boolLabel(config.vetoBlocksVerdict))")
        writeStdout()
        writeStdout("Actions")
        writeStdout("  1. Use one provider/class for all members")
        writeStdout("  2. Edit one member")
        writeStdout("  3. Toggle web access")
        writeStdout("  4. Toggle evidence approval")
        writeStdout("  5. Toggle deadlock extra round")
        writeStdout("  6. Toggle veto blocks verdict")
        writeStdout("  7. Run doctor")
        writeStdout("  8. Check/create persona files")
        writeMuted("Press return, q, or back to close.")
    }

    private func promptMemberID() -> MagiMemberID? {
        writeChoiceLines(["Member choices"] + MagiMemberID.allCases.enumerated().map { index, memberID in
            "  \(index + 1). \(memberID.displayName)"
        })
        let value = prompt("Choose member:").lowercased()
        if value.isEmpty { return nil }

        switch value {
        case "1", "melchior":
            return .melchior
        case "2", "balthasar":
            return .balthasar
        case "3", "casper":
            return .casper
        default:
            writeStdout("Choose Melchior, Balthasar, or Casper.")
            return nil
        }
    }

    private func runDoctor() -> MagiCLIExitCode {
        printHeader()
        writeStdout("Doctor")
        writeStdout("Global config: \(paths.globalConfigPath)")
        writeStdout("Personas: \(paths.globalPersonaDirectory)")
        let socketPath = "\(paths.homeDirectory)/.chau7/mcp.sock"
        let socketStatus = fileManager.fileExists(atPath: socketPath) ? "present" : "missing"
        writeStdout("Chau7 MCP socket: \(socketPath) (\(socketStatus))")
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
            FileHandle.standardError.writeLine(nonInteractiveConfigMessage)
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
        writeWizardTitle("First-run configuration")
        writeMuted("Reasoning defaults to max. You can edit files after setup.")
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

        writeWizardSection("Setup mode")
        writeStdout("Members: \(MagiMemberID.allCases.map(\.displayName).joined(separator: ", "))")
        if promptYesNo("Use the same provider and class for all members?", defaultValue: true) {
            writeStdout()
            writeWizardSection("Shared member config")
            let provider = promptProvider(defaultValue: .codex)
            let modelClass = promptModelClass(defaultValue: .balanced)
            selections = MagiFirstRunPlanner.sharedSelections(
                provider: provider,
                modelClass: modelClass,
                reasoning: .max
            )
            writeStdout()
            writeMuted("Applied to \(MagiMemberID.allCases.map(\.displayName).joined(separator: ", ")).")
            writeStdout()
            return selections
        }

        writeStdout()
        for (index, memberID) in MagiMemberID.allCases.enumerated() {
            let current = selections[memberID] ?? MagiFirstRunMemberSelection(memberID: memberID, provider: .codex)
            writeWizardSection("Member \(index + 1) of \(MagiMemberID.allCases.count): \(memberID.displayName)")
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
            writeChoiceLines(MagiFirstRunPromptText.providerChoiceLines(defaultValue: defaultValue))
            let value = prompt("Choose provider:")
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
            writeChoiceLines(MagiFirstRunPromptText.modelClassChoiceLines(defaultValue: defaultValue))
            let value = prompt("Choose class:")
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
        writeStdout(styled(message, .bold), terminator: " ")
        fflush(stdout)
        return readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func writeChoiceLines(_ lines: [String]) {
        for (index, line) in lines.enumerated() {
            if index == 0 {
                writeMuted(line)
            } else {
                writeStdout(line)
            }
        }
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

    private func saveConfig(_ config: MagiConfig) throws {
        try fileManager.createDirectory(
            at: URL(fileURLWithPath: paths.globalRoot),
            withIntermediateDirectories: true
        )
        try MagiConfigTOMLCodec.encode(config).write(
            to: URL(fileURLWithPath: paths.globalConfigPath),
            atomically: true,
            encoding: .utf8
        )
        _ = try MagiFirstRunInstaller.install(
            config: config,
            paths: paths,
            fileManager: fileManager,
            overwrite: false
        )
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

    private func supportsANSIOutput() -> Bool {
        guard isInteractiveTerminal else { return false }
        if environment["NO_COLOR"] != nil { return false }
        return environment["TERM"] != "dumb"
    }

    private var nonInteractiveConfigMessage: String {
        let stdinTTY = isatty(STDIN_FILENO) != 0
        let stdoutTTY = isatty(STDOUT_FILENO) != 0
        return """
        MAGI is not configured and cannot open the first-run wizard because stdin/stdout are not both interactive terminals.
        Detected stdin_tty=\(stdinTTY) stdout_tty=\(stdoutTTY).
        Run `magi config` directly from a terminal, or run `.build/debug/magi config` from apps/chau7-macos until MAGI is installed on PATH.
        """
    }

    private func writeStdout(_ line: String = "", terminator: String = "\n") {
        FileHandle.standardOutput.writeText("\(line)\(terminator)")
    }

    private func writeWizardTitle(_ title: String) {
        writeStdout(styled(title, .bold, .cyan))
        writeStdout(styled(String(repeating: "=", count: title.count), .cyan))
    }

    private func writeWizardSection(_ title: String) {
        writeStdout(styled("-- \(title)", .bold, .cyan))
    }

    private func writeMuted(_ line: String) {
        writeStdout(styled(line, .dim))
    }

    private func writeSaved(_ message: String = "Saved.") {
        writeStdout(styled(message, .green))
    }

    private func boolLabel(_ value: Bool) -> String {
        value ? styled("enabled", .green) : styled("disabled", .yellow)
    }

    private func styled(_ text: String, _ styles: ANSIStyle...) -> String {
        guard supportsANSIOutput(), !styles.isEmpty else { return text }
        let prefix = styles.map(\.rawValue).joined(separator: ";")
        return "\u{001B}[\(prefix)m\(text)\u{001B}[0m"
    }

    private func printHeader() {
        writeStdout("MAGI")
        writeStdout("Multi Agent Gathering Intelligence")
        writeStdout()
    }

    private func printExistingShare(runID: String, bundle: MagiArtifactBundle) -> MagiCLIExitCode {
        printHeader()
        writeStdout("Share")
        writeStdout("Run id: \(runID)")
        writeStdout("Existing local share HTML: \(bundle.shareHTMLPath)")
        writeStdout("Hosted upload: disabled in v1")
        return .success
    }

    private func writePreflightFailureArtifact(
        question: String,
        config: MagiConfig,
        error: Error,
        category: MagiRunFailureCategory
    ) -> MagiArtifactBundle? {
        let runID = MagiRunID.make()
        let repositoryRoot = paths.repositoryRoot(fileManager: fileManager)
        let artifactRoot = paths.runRoot(runID: runID, repositoryRoot: repositoryRoot)
        var run = MagiRun(
            id: runID,
            question: question,
            council: MagiCouncil.defaultMagi(members: config.members),
            status: .running,
            artifactBundle: MagiArtifactBundle(runID: runID, rootDirectory: artifactRoot),
            metadata: [
                "mcp_socket": "\(paths.homeDirectory)/.chau7/mcp.sock",
                "artifact_root": artifactRoot,
                "artifact_scope": repositoryRoot == nil ? "global" : "repository",
                "repository_root": repositoryRoot ?? "",
                "preflight": "true"
            ]
        )
        MagiRunStateMachine.markFailed(
            &run,
            category: category,
            stage: "mcp-preflight",
            message: error.localizedDescription
        )
        return try? MagiRunArtifactStore.write(run: run, fileManager: fileManager)
    }

    private func preflightFailureCategory(for error: Error) -> MagiRunFailureCategory {
        switch error {
        case MagiMCPClientError.socketMissing(_):
            return .mcpSocketMissing
        case MagiMCPClientError.connectFailed(_, _),
             MagiMCPClientError.readTimedOut,
             MagiMCPClientError.disconnected:
            return .chau7Unavailable
        default:
            return .unknown
        }
    }

    static let usage = """
    MAGI - Multi Agent Gathering Intelligence

    Usage:
      magi
      magi "question"
      magi ask "question"
      magi doctor
      magi config
      magi --config
      magi replay <run-id>
      magi share <run-id>

    First run:
      magi
      magi --config

    MAGI is also supported as a command name on supported installations.
    """
}

private enum ANSIStyle: String {
    case bold = "1"
    case dim = "2"
    case cyan = "36"
    case green = "32"
    case yellow = "33"
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

final class MagiInterruptFlag {
    static let shared = MagiInterruptFlag()

    private let lock = NSLock()
    private var didInterrupt = false
    private var signalSource: DispatchSourceSignal?

    var isInterrupted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didInterrupt
    }

    func install() {
        lock.lock()
        didInterrupt = false
        let alreadyInstalled = signalSource != nil
        lock.unlock()

        guard !alreadyInstalled else { return }

        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global(qos: .userInitiated))
        source.setEventHandler {
            MagiInterruptFlag.shared.markInterrupted()
        }
        source.resume()

        lock.lock()
        signalSource = source
        lock.unlock()
    }

    private func markInterrupted() {
        lock.lock()
        didInterrupt = true
        lock.unlock()
    }
}

let paths = MagiCLIPaths(
    homeDirectory: environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path,
    currentDirectory: FileManager.default.currentDirectoryPath
)
let runner = MagiCLIRunner(paths: paths)
let exitCode = runner.run(arguments: Array(CommandLine.arguments.dropFirst()))
Foundation.exit(exitCode.rawValue)
