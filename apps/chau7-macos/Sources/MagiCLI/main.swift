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
}

let paths = MagiCLIPaths(
    homeDirectory: environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path,
    currentDirectory: FileManager.default.currentDirectoryPath
)
let runner = MagiCLIRunner(paths: paths)
let exitCode = runner.run(arguments: Array(CommandLine.arguments.dropFirst()))
Foundation.exit(exitCode.rawValue)
