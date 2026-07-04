import Chau7Core
import Darwin
import Foundation

extension MagiCLIRunner {
    func printMembers(_ config: MagiConfig) {
        writeStdout("Members")
        let council = MagiCouncil.defaultMagi(members: config.members)
        for member in council.members {
            let launchCommand = MagiProviderCommandBuilder.command(for: member)
            let model = launchCommand.resolvedModel ?? member.modelName ?? "custom"
            let reasoning = launchCommand.resolvedReasoning ?? "not supported by provider CLI"
            writeStdout("- \(member.id.displayName): provider=\(member.provider), class=\(member.modelClass.rawValue), model=\(model), reasoning=\(member.reasoning.rawValue)")
            writeMuted("  launch: \(launchCommand.commandLine)")
            writeMuted("  cli reasoning: \(reasoning)")
        }
    }

    func printMissingPersonas() {
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

    func loadConfig() throws -> MagiConfig {
        let content = try String(contentsOfFile: paths.globalConfigPath, encoding: .utf8)
        return try MagiConfigTOMLCodec.decode(content)
    }

    func saveConfig(_ config: MagiConfig) throws {
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

    func selections(from config: MagiConfig) -> [MagiMemberID: MagiFirstRunMemberSelection] {
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

    var isInteractiveTerminal: Bool {
        isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
    }

    func supportsANSIOutput() -> Bool {
        guard isInteractiveTerminal else { return false }
        if environment["NO_COLOR"] != nil { return false }
        return environment["TERM"] != "dumb"
    }

    var nonInteractiveConfigMessage: String {
        let stdinTTY = isatty(STDIN_FILENO) != 0
        let stdoutTTY = isatty(STDOUT_FILENO) != 0
        return """
        MAGI is not configured and cannot open the first-run wizard because stdin/stdout are not both interactive terminals.
        Detected stdin_tty=\(stdinTTY) stdout_tty=\(stdoutTTY).
        Run `magi config` directly from a terminal, or run `.build/debug/magi config` from apps/chau7-macos until MAGI is installed on PATH.
        """
    }

    func writeStdout(_ line: String = "", terminator: String = "\n") {
        FileHandle.standardOutput.writeText("\(line)\(terminator)")
    }

    func writeWizardTitle(_ title: String) {
        writeStdout(styled(title, .bold, .cyan))
        writeStdout(styled(String(repeating: "=", count: title.count), .cyan))
    }

    func writeWizardSection(_ title: String) {
        writeStdout(styled("-- \(title)", .bold, .cyan))
    }

    func writeMuted(_ line: String) {
        writeStdout(styled(line, .dim))
    }

    func writeProgressive(
        _ text: String,
        styles: [ANSIStyle] = [],
        lineDelay: TimeInterval = 0.06
    ) {
        for line in text.components(separatedBy: .newlines) {
            guard !line.isEmpty else { continue }
            writeStdout(styled(line, styles: styles))
            pauseBoot(lineDelay)
        }
    }

    func pauseBoot(_ seconds: TimeInterval = 0.14) {
        Thread.sleep(forTimeInterval: seconds)
    }

    func writeSaved(_ message: String = "Saved.") {
        writeStdout(styled(message, .green))
    }

    func boolLabel(_ value: Bool) -> String {
        value ? styled("enabled", .green) : styled("disabled", .yellow)
    }

    func styled(_ text: String, _ styles: ANSIStyle...) -> String {
        styled(text, styles: styles)
    }

    func styled(_ text: String, styles: [ANSIStyle]) -> String {
        guard supportsANSIOutput(), !styles.isEmpty else { return text }
        let prefix = styles.map(\.rawValue).joined(separator: ";")
        return "\u{001B}[\(prefix)m\(text)\u{001B}[0m"
    }

    func printHeader() {
        writeStdout(styled("MAGI", .bold, .cyan))
        writeStdout(styled("Multi Agent Gathering Intelligence", .dim))
        writeStdout()
    }

    func writePreflightFailureArtifact(
        question: String,
        config: MagiConfig,
        mode: MagiQuestionKind?,
        error: Error,
        category: MagiRunFailureCategory
    ) -> MagiArtifactBundle? {
        let runID = MagiRunID.make()
        let repositoryRoot = paths.repositoryRoot(fileManager: fileManager)
        let artifactRoot = paths.runRoot(runID: runID, repositoryRoot: repositoryRoot)
        let artifactBundle = MagiArtifactBundle(runID: runID, rootDirectory: artifactRoot)
        let modeSelection = questionModeSelection(question: question, override: mode)
        let technicalLog = MagiTechnicalLog(
            path: artifactBundle.technicalLogPath,
            runID: runID,
            fileManager: fileManager
        )
        var run = MagiRun(
            id: runID,
            question: question,
            council: MagiCouncil.defaultMagi(members: config.members),
            status: .running,
            artifactBundle: artifactBundle,
            metadata: [
                "mcp_socket": "\(paths.homeDirectory)/.chau7/mcp.sock",
                "question_kind": modeSelection.kind.rawValue,
                "question_kind_source": mode == nil ? "inferred" : "explicit",
                "question_kind_reason": modeSelection.reason,
                "artifact_root": artifactRoot,
                "technical_log": artifactBundle.technicalLogPath,
                "artifact_scope": repositoryRoot == nil ? "global" : "repository",
                "repository_root": repositoryRoot ?? "",
                "preflight": "true"
            ]
        )
        technicalLog.record(
            "preflight_failed",
            stage: "mcp-preflight",
            level: "error",
            message: error.localizedDescription,
            fields: ["category": category.rawValue]
        )
        MagiRunStateMachine.markFailed(
            &run,
            category: category,
            stage: "mcp-preflight",
            message: error.localizedDescription
        )
        return try? MagiRunArtifactStore.write(run: run, fileManager: fileManager)
    }

    func questionModeSelection(
        question: String,
        override: MagiQuestionKind?
    ) -> MagiQuestionKindInference {
        if let override {
            return MagiQuestionKindInference(kind: override, reason: "explicit --mode")
        }
        return MagiQuestionKind.inferWithReason(from: question)
    }

    func preflightFailureCategory(for error: Error) -> MagiRunFailureCategory {
        switch error {
        case MagiMCPClientError.socketMissing:
            return .mcpSocketMissing
        case MagiMCPClientError.connectFailed(_, _),
             MagiMCPClientError.readTimedOut,
             MagiMCPClientError.disconnected:
            return .chau7Unavailable
        default:
            return .unknown
        }
    }

}
