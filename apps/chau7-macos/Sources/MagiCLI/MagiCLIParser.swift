import Chau7Core
import Darwin
import Foundation

extension MagiCLIRunner {
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

    func execute(_ command: MagiCLICommand) -> MagiCLIExitCode {
        switch command {
        case let .ask(question, mode):
            if let exitCode = ensureConfiguredForRun() {
                return exitCode
            }
            return runAsk(question: question, mode: mode)
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

    func runAsk(
        question: String,
        mode: MagiQuestionKind?,
        showLaunchBanner: Bool = true
    ) -> MagiCLIExitCode {
        do {
            let config = try loadConfig()
            let client = MagiMCPClient(socketPath: "\(paths.homeDirectory)/.chau7/mcp.sock")
            do {
                try client.connectAndInitialize()
                try verifyMCPCompatibility(client: client)
            } catch {
                let bundle = writePreflightFailureArtifact(
                    question: question,
                    config: config,
                    mode: mode,
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
            if showLaunchBanner {
                printRunLaunchBanner(config: config)
            }
            let councilArt = loadCouncilArt(councilID: config.defaultCouncilID)
            let orchestrator = MagiMCPOrchestrator(
                client: client,
                paths: paths,
                fileManager: fileManager,
                isInteractive: isInteractiveTerminal,
                isInterrupted: { interruptFlag.isInterrupted },
                processingLines: councilArt.processingLines
            )
            _ = try orchestrator.run(question: question, config: config, mode: mode)
            return .success
        } catch {
            FileHandle.standardError.writeLine("MAGI: \(error.localizedDescription)")
            return .unavailable
        }
    }

    static let usage = """
    MAGI - Multi Agent Gathering Intelligence

    Usage:
      magi
      magi "question"
      magi --mode engineering "question"
      magi --mode generic "question"
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
