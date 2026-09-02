import Foundation
import Chau7Core

/// Pull-based Chau7 adapter for Aethyme's provider-neutral delivery outbox.
///
/// Aethyme remains the durable authority for observation, deduplication,
/// authorization policy, and retries. Chau7 only resolves an exact local
/// recipient and reports a fenced delivery outcome.
final class AethymeDeliveryMonitor {
    static let shared = AethymeDeliveryMonitor()

    private struct CommandResult {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    private let queue = DispatchQueue(label: "com.chau7.aethyme-delivery", qos: .utility)
    private let worker = "chau7-\(ProcessInfo.processInfo.processIdentifier)"
    private var timer: DispatchSourceTimer?
    private var cycleInProgress = false
    private var unsupportedUntil: Date?
    private var didLogUnavailable = false

    private init() {}

    func start() {
        queue.async { [weak self] in
            guard let self, timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 15, repeating: 30, leeway: .seconds(3))
            timer.setEventHandler { [weak self] in self?.runCycle() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    private func runCycle() {
        guard !cycleInProgress else { return }
        guard unsupportedUntil.map({ $0 <= Date() }) ?? true else { return }
        guard resolveAethymeExecutable() != nil else {
            if !didLogUnavailable {
                didLogUnavailable = true
                Log.info("Aethyme PR delivery is inactive because the aethyme binary is unavailable")
            }
            return
        }

        cycleInProgress = true
        defer { cycleInProgress = false }
        for repositoryRoot in liveRepositoryRoots() {
            pollDueWatches(repositoryRoot: repositoryRoot)
            drainDeliveries(repositoryRoot: repositoryRoot)
        }
    }

    private func liveRepositoryRoots() -> [String] {
        let summaries = TerminalControlService.shared.liveTabSummaries()
        let roots = summaries.compactMap { $0["repo_root"] as? String }.filter { !$0.isEmpty }
        return Array(Set(roots.map(canonicalPath))).sorted()
    }

    private func pollDueWatches(repositoryRoot: String) {
        guard let result = runAethyme(
            arguments: AethymeDeliveryCommand.listWatches(),
            repositoryRoot: repositoryRoot
        ) else { return }
        guard result.status == 0 else {
            noteUnsupportedIfNeeded(result)
            return
        }
        guard let watches = try? JSONDecoder().decode([AethymePullRequestWatch].self, from: result.stdout) else {
            Log.warn("Aethyme PR watch list returned an incompatible response")
            return
        }

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for watch in watches
            .filter({ $0.status == "active" && ($0.nextPollAt ?? 0) <= now })
            .prefix(4) {
            _ = runAethyme(
                arguments: AethymeDeliveryCommand.pollWatch(id: watch.id),
                repositoryRoot: repositoryRoot
            )
        }
    }

    private func drainDeliveries(repositoryRoot: String) {
        for _ in 0 ..< 4 {
            guard let result = runAethyme(
                arguments: AethymeDeliveryCommand.claim(worker: worker),
                repositoryRoot: repositoryRoot
            ) else { return }
            guard result.status == 0 else {
                noteUnsupportedIfNeeded(result)
                return
            }
            guard let report = try? JSONDecoder().decode(AethymeDeliveryClaimReport.self, from: result.stdout) else {
                Log.warn("Aethyme delivery claim returned an incompatible response")
                return
            }
            guard let envelope = report.delivery else { return }
            guard let target = AethymeDeliveryTarget(opaqueValue: envelope.subscription.target) else {
                complete(
                    envelope: envelope,
                    outcome: "failed",
                    errorCode: "invalid_chau7_target",
                    repositoryRoot: repositoryRoot
                )
                continue
            }

            let prompt = "[Aethyme delivery #\(envelope.item.id)]\n\(envelope.prompt)"
            switch TerminalControlService.shared.deliverAethymePrompt(
                target: target,
                repositoryRoot: repositoryRoot,
                prompt: prompt
            ) {
            case .ready:
                complete(
                    envelope: envelope,
                    outcome: "delivered",
                    errorCode: nil,
                    repositoryRoot: repositoryRoot
                )
            case let .retry(errorCode):
                complete(
                    envelope: envelope,
                    outcome: "retry",
                    errorCode: errorCode,
                    repositoryRoot: repositoryRoot
                )
                return
            case let .failed(errorCode):
                complete(
                    envelope: envelope,
                    outcome: "failed",
                    errorCode: errorCode,
                    repositoryRoot: repositoryRoot
                )
            }
        }
    }

    private func complete(
        envelope: AethymeDeliveryEnvelope,
        outcome: String,
        errorCode: String?,
        repositoryRoot: String
    ) {
        guard let result = runAethyme(
            arguments: AethymeDeliveryCommand.complete(
                id: envelope.item.id,
                worker: worker,
                generation: envelope.item.generation,
                outcome: outcome,
                errorCode: errorCode
            ),
            repositoryRoot: repositoryRoot
        ), result.status == 0 else {
            Log.warn("Aethyme delivery completion failed; its claim will expire safely")
            return
        }
    }

    private func noteUnsupportedIfNeeded(_ result: CommandResult) {
        let message = String(decoding: result.stderr, as: UTF8.self).lowercased()
        guard message.contains("unknown") || message.contains("upgrade") || message.contains("schema") else {
            return
        }
        unsupportedUntil = Date().addingTimeInterval(10 * 60)
        if !didLogUnavailable {
            didLogUnavailable = true
            Log.info("Aethyme PR delivery requires a compatible Aethyme deployment")
        }
    }

    private func runAethyme(arguments: [String], repositoryRoot: String) -> CommandResult? {
        guard let executable = resolveAethymeExecutable() else { return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: repositoryRoot, isDirectory: true)
        var environment = ProcessInfo.processInfo.environment
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["NO_COLOR"] = "1"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            if !didLogUnavailable {
                didLogUnavailable = true
                Log.info("Aethyme PR delivery could not launch the aethyme binary")
            }
            return nil
        }
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(
            status: process.terminationStatus,
            stdout: stdoutData,
            stderr: stderrData
        )
    }

    private func resolveAethymeExecutable() -> URL? {
        var candidates = ["/opt/homebrew/bin/aethyme", "/usr/local/bin/aethyme"]
        candidates.append(
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".cargo/bin/aethyme")
                .path
        )
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/aethyme" })
        }
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:)).map {
            URL(fileURLWithPath: $0)
        }
    }

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
