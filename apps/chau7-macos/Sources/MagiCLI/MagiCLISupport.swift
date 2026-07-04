import Chau7Core
import Darwin
import Foundation

enum ANSIStyle: String {
    case bold = "1"
    case dim = "2"
    case cyan = "36"
    case green = "32"
    case yellow = "33"
    case magenta = "35"
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

