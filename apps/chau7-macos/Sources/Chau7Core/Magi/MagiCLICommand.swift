import Foundation

public enum MagiCLICommand: Equatable, Sendable {
    case ask(question: String, mode: MagiQuestionKind?)
    case doctor
    case config
    case home
    case replay(runID: String)
    case share(runID: String)
    case help
    case version
}

public enum MagiCLIParseError: Equatable, LocalizedError, Sendable {
    case missingQuestion
    case missingRunID(command: String)
    case unknownOption(String)
    case missingOptionValue(String)
    case invalidMode(String)
    case unsupportedModeOption(command: String)

    public var errorDescription: String? {
        switch self {
        case .missingQuestion:
            return "Missing question. Usage: magi \"question\""
        case let .missingRunID(command):
            return "Missing run id. Usage: magi \(command) <run-id>"
        case let .unknownOption(option):
            return "Unknown option: \(option)"
        case let .missingOptionValue(option):
            return "Missing value for \(option). Use engineering or generic."
        case let .invalidMode(value):
            return "Invalid mode: \(value). Use engineering or generic."
        case let .unsupportedModeOption(command):
            return "--mode is only supported for questions, not \(command)."
        }
    }
}

public enum MagiCLICommandParser {
    public static func parse(_ arguments: [String]) -> Result<MagiCLICommand, MagiCLIParseError> {
        let rawArguments = arguments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let options: ParsedOptions
        do {
            options = try parseOptions(rawArguments)
        } catch let error as MagiCLIParseError {
            return .failure(error)
        } catch {
            return .failure(.unknownOption(error.localizedDescription))
        }

        let trimmed = options.arguments
        guard let first = trimmed.first else {
            if options.mode != nil {
                return .failure(.missingQuestion)
            }
            return .success(.home)
        }

        switch first {
        case "-h", "--help", "help":
            guard options.mode == nil else { return .failure(.unsupportedModeOption(command: "help")) }
            return .success(.help)
        case "--config":
            guard options.mode == nil else { return .failure(.unsupportedModeOption(command: "config")) }
            return .success(.config)
        case "-v", "--version", "version":
            guard options.mode == nil else { return .failure(.unsupportedModeOption(command: "version")) }
            return .success(.version)
        case "ask":
            let question = joinedRemainder(trimmed.dropFirst())
            return question.isEmpty ? .failure(.missingQuestion) : .success(.ask(question: question, mode: options.mode))
        case "doctor":
            guard options.mode == nil else { return .failure(.unsupportedModeOption(command: "doctor")) }
            return .success(.doctor)
        case "config":
            guard options.mode == nil else { return .failure(.unsupportedModeOption(command: "config")) }
            return .success(.config)
        case "replay":
            guard options.mode == nil else { return .failure(.unsupportedModeOption(command: "replay")) }
            guard let runID = trimmed.dropFirst().first else {
                return .failure(.missingRunID(command: "replay"))
            }
            return .success(.replay(runID: runID))
        case "share":
            guard options.mode == nil else { return .failure(.unsupportedModeOption(command: "share")) }
            guard let runID = trimmed.dropFirst().first else {
                return .failure(.missingRunID(command: "share"))
            }
            return .success(.share(runID: runID))
        default:
            if first.hasPrefix("-") {
                return .failure(.unknownOption(first))
            }
            return .success(.ask(question: joinedRemainder(trimmed[...]), mode: options.mode))
        }
    }

    private struct ParsedOptions {
        var arguments: [String]
        var mode: MagiQuestionKind?
    }

    private static func parseOptions(_ arguments: [String]) throws -> ParsedOptions {
        var remaining: [String] = []
        var mode: MagiQuestionKind?
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--mode" {
                let valueIndex = index + 1
                guard valueIndex < arguments.count else {
                    throw MagiCLIParseError.missingOptionValue("--mode")
                }
                mode = try parseMode(arguments[valueIndex])
                index += 2
                continue
            }
            if argument.hasPrefix("--mode=") {
                let value = String(argument.dropFirst("--mode=".count))
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw MagiCLIParseError.missingOptionValue("--mode")
                }
                mode = try parseMode(value)
                index += 1
                continue
            }
            remaining.append(argument)
            index += 1
        }

        return ParsedOptions(arguments: remaining, mode: mode)
    }

    private static func parseMode(_ value: String) throws -> MagiQuestionKind {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let mode = MagiQuestionKind(rawValue: normalized) else {
            throw MagiCLIParseError.invalidMode(value)
        }
        return mode
    }

    private static func joinedRemainder(_ values: some Sequence<String>) -> String {
        values.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct MagiCLIPaths: Codable, Equatable, Sendable {
    public let homeDirectory: String
    public let currentDirectory: String

    public init(homeDirectory: String, currentDirectory: String) {
        self.homeDirectory = homeDirectory
        self.currentDirectory = currentDirectory
    }

    public var globalRoot: String {
        "\(homeDirectory)/.chau7/magi"
    }

    public var globalConfigPath: String {
        "\(globalRoot)/config.toml"
    }

    public var globalPersonaDirectory: String {
        "\(globalRoot)/personas"
    }

    public var globalCouncilDirectory: String {
        "\(globalRoot)/councils"
    }

    public func personaPath(for memberID: MagiMemberID) -> String {
        "\(globalPersonaDirectory)/\(MagiPersonaFile.fileName(for: memberID))"
    }

    public func councilPath(for councilID: String) -> String {
        "\(globalCouncilDirectory)/\(MagiCouncilArtFile.fileName(for: councilID))"
    }

    public func runRoot(runID: String, repositoryRoot: String?) -> String {
        MagiArtifactBundle.rootDirectory(
            runID: runID,
            repositoryRoot: repositoryRoot,
            homeDirectory: homeDirectory
        )
    }

    public func repositoryRoot(fileManager: FileManager = .default) -> String? {
        MagiRepositoryLocator.repositoryRoot(
            startingAt: currentDirectory,
            fileManager: fileManager
        )
    }

    public func resolvedRunRoot(runID: String, fileManager: FileManager = .default) -> String {
        runRoot(
            runID: runID,
            repositoryRoot: repositoryRoot(fileManager: fileManager)
        )
    }

    public func artifactBundle(runID: String, fileManager: FileManager = .default) -> MagiArtifactBundle {
        MagiArtifactBundle(
            runID: runID,
            rootDirectory: resolvedRunRoot(runID: runID, fileManager: fileManager)
        )
    }

    public func artifactCandidateBundles(
        runID: String,
        fileManager: FileManager = .default
    ) -> [MagiArtifactBundle] {
        var bundles: [MagiArtifactBundle] = []
        if let repositoryRoot = repositoryRoot(fileManager: fileManager) {
            bundles.append(
                MagiArtifactBundle(
                    runID: runID,
                    rootDirectory: runRoot(runID: runID, repositoryRoot: repositoryRoot)
                )
            )
        }

        let globalBundle = MagiArtifactBundle(
            runID: runID,
            rootDirectory: runRoot(runID: runID, repositoryRoot: nil)
        )
        if !bundles.contains(where: { $0.rootDirectory == globalBundle.rootDirectory }) {
            bundles.append(globalBundle)
        }
        return bundles
    }
}
