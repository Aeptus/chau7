import Darwin
import Foundation

let runner = Chau7CLIRunner()
let result = runner.run(arguments: Array(ProcessInfo.processInfo.arguments.dropFirst()))

if !result.stdout.isEmpty {
    FileHandle.standardOutput.write(Data(result.stdout.utf8))
}

if !result.stderr.isEmpty {
    FileHandle.standardError.write(Data(result.stderr.utf8))
}

exit(result.exitCode)
