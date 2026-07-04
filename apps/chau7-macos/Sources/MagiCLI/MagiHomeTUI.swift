import Chau7Core
import Darwin
import Foundation

extension MagiCLIRunner {
    func runHome() -> MagiCLIExitCode {
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
                let askRequest: HomeAskRequest
                switch parseHomeAskInput(value) {
                case let .success(request):
                    askRequest = request
                case let .failure(error):
                    FileHandle.standardError.writeLine("MAGI: \(error.localizedDescription)")
                    writeMuted("Ask a question, type --config, doctor, help, or quit.")
                    continue
                }
                if let exitCode = ensureConfiguredForRun() {
                    return exitCode
                }
                _ = runAsk(question: askRequest.question, mode: askRequest.mode, showLaunchBanner: false)
                writeStdout()
                writeMuted("Ask a question, type --config, doctor, help, or quit.")
            }
        }
    }

    struct HomeAskRequest {
        var question: String
        var mode: MagiQuestionKind?
    }

    func parseHomeAskInput(_ value: String) -> Result<HomeAskRequest, MagiCLIParseError> {
        let tokens = value.split(whereSeparator: \.isWhitespace).map(String.init)
        let shouldParseAsCommand = tokens.first == "ask"
            || tokens.contains("--mode")
            || tokens.contains(where: { $0.hasPrefix("--mode=") })
        guard shouldParseAsCommand else {
            return .success(HomeAskRequest(question: value, mode: nil))
        }

        switch MagiCLICommandParser.parse(tokens) {
        case let .success(.ask(question, mode)):
            return .success(HomeAskRequest(question: question, mode: mode))
        case let .success(command):
            return .failure(.unsupportedModeOption(command: "\(command)"))
        case let .failure(error):
            return .failure(error)
        }
    }

    func printHomeScreen() {
        let config = try? loadConfig()
        let councilID = config?.defaultCouncilID ?? "magi"
        let councilArt = loadCouncilArt(councilID: councilID)

        printMagiASCII()
        writeStdout(styled("WELCOME TO MAGI SYSTEM", .bold))
        pauseBoot(0.22)
        writeStdout()
        printBootLine("core protocol", "Multi Agent Gathering Intelligence online")
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
        printBootLine("council", "selected: \(councilArt.displayName) (\(councilID))")
        writeStdout()
        printCouncilArt(councilArt)
        writeStdout()
        writeMuted("Ask a question, type --config, doctor, help, or quit.")
    }

    func printRunLaunchBanner(config: MagiConfig) {
        guard isInteractiveTerminal else {
            printHeader()
            return
        }

        let councilArt = loadCouncilArt(councilID: config.defaultCouncilID)
        printMagiASCII()
        printBootLine("core protocol", "Multi Agent Gathering Intelligence online")
        printBootLine("council", "selected: \(councilArt.displayName) (\(config.defaultCouncilID))")
        writeStdout()
        printCouncilArt(councilArt)
        writeStdout()
    }

    func printMagiASCII() {
        let art = """
        __  __    _    ____ ___
        |  \\/  |  / \\  / ___|_ _|
        | |\\/| | / _ \\| |  _ | |
        | |  | |/ ___ \\ |_| || |
        |_|  |_/_/   \\_\\____|___|
        """
        writeProgressive(art, styles: [.bold, .cyan], lineDelay: 0.045)
    }

    func printCouncilArt(_ art: MagiCouncilArt) {
        writeProgressive(
            art.asciiArt,
            styles: [.bold, ansiStyle(named: art.color) ?? .cyan],
            lineDelay: 0.035
        )
    }

    func loadCouncilArt(councilID: String) -> MagiCouncilArt {
        let path = paths.councilPath(for: councilID)
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return MagiCouncilArtFile.defaultArt(councilID: councilID, displayName: councilID.uppercased())
        }
        return MagiCouncilArtFile.parse(councilID: councilID, content: content)
    }

    func ansiStyle(named color: String) -> ANSIStyle? {
        switch color.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "cyan", "blue":
            return .cyan
        case "green":
            return .green
        case "yellow":
            return .yellow
        case "magenta", "purple":
            return .magenta
        default:
            return nil
        }
    }

    func printBootLine(_ label: String, _ detail: String, ok: Bool = true) {
        let status = ok ? styled("[ OK ]", .green) : styled("[ .. ]", .yellow)
        writeStdout("\(status) \(label.padding(toLength: 14, withPad: " ", startingAt: 0)) \(detail)")
        pauseBoot()
    }

    func printHomeHelp() {
        writeStdout()
        writeWizardSection("Home commands")
        writeStdout("Type any question to ask the council.")
        writeStdout("--mode engineering <question>  Force approve/reject-style verdicts.")
        writeStdout("--mode generic <question>      Force select/rank verdicts.")
        writeStdout("--config  Open the configuration panel.")
        writeStdout("doctor    Check config, personas, MCP socket, and providers.")
        writeStdout("quit      Exit MAGI.")
    }

}
