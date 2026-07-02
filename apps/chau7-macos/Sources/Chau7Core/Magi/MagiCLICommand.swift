import Foundation

public enum MagiCLICommand: Equatable, Sendable {
    case ask(question: String)
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

    public var errorDescription: String? {
        switch self {
        case .missingQuestion:
            return "Missing question. Usage: magi \"question\""
        case let .missingRunID(command):
            return "Missing run id. Usage: magi \(command) <run-id>"
        case let .unknownOption(option):
            return "Unknown option: \(option)"
        }
    }
}

public enum MagiCLICommandParser {
    public static func parse(_ arguments: [String]) -> Result<MagiCLICommand, MagiCLIParseError> {
        let trimmed = arguments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let first = trimmed.first else {
            return .success(.home)
        }

        switch first {
        case "-h", "--help", "help":
            return .success(.help)
        case "--config":
            return .success(.config)
        case "-v", "--version", "version":
            return .success(.version)
        case "ask":
            let question = joinedRemainder(trimmed.dropFirst())
            return question.isEmpty ? .failure(.missingQuestion) : .success(.ask(question: question))
        case "doctor":
            return .success(.doctor)
        case "config":
            return .success(.config)
        case "replay":
            guard let runID = trimmed.dropFirst().first else {
                return .failure(.missingRunID(command: "replay"))
            }
            return .success(.replay(runID: runID))
        case "share":
            guard let runID = trimmed.dropFirst().first else {
                return .failure(.missingRunID(command: "share"))
            }
            return .success(.share(runID: runID))
        default:
            if first.hasPrefix("-") {
                return .failure(.unknownOption(first))
            }
            return .success(.ask(question: joinedRemainder(trimmed[...])))
        }
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

    public func personaPath(for memberID: MagiMemberID) -> String {
        "\(globalPersonaDirectory)/\(MagiPersonaFile.fileName(for: memberID))"
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
