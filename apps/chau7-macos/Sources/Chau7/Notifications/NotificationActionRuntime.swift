import Foundation

/// Shared runtime helpers for `NotificationActionExecutor` action
/// implementations. Two responsibilities:
///
/// 1. **ProcessRunner.terminate(_:gracePeriod:)** — escalates a long-
///    running child process: SIGTERM, wait `gracePeriod` seconds for it
///    to settle, then SIGKILL if it's still alive. The previous
///    `executeRunScript` timeout only called `process.terminate()` and
///    walked away — a script that traps SIGTERM would hang indefinitely.
/// 2. **NotificationActionHTTP.session** — a purpose-built `URLSession`
///    for webhook / Slack / Discord outbound calls. Configured with
///    explicit request/resource timeouts and a connection cap so the
///    "fire one webhook" path can't hold open URLSession.shared
///    resources for the lifetime of the app.
enum NotificationActionRuntime {

    /// Seconds between SIGTERM and SIGKILL for a hung child process.
    /// Chosen to give well-behaved shell scripts time to flush stdout
    /// without letting a runaway process linger.
    static let processKillGracePeriod: TimeInterval = 3.0
}

/// Synchronously runs a process, draining stdout/stderr into a log line
/// on non-zero exits. Pure function — safe to call from any thread.
/// Used by every "shell-out" action that doesn't need streaming output
/// (docker, kubernetes, git-commit). Returns true on exit code 0.
@discardableResult
func runProcessSync(
    executable: String,
    arguments: [String],
    currentDirectory: String? = nil,
    label: String
) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    if let currentDirectory {
        process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
    }

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    do {
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            Log.warn("Action \(label): Exit code \(process.terminationStatus), output: \(output.prefix(200))")
            return false
        }
        return true
    } catch {
        Log.error("Action \(label): Failed: \(error.localizedDescription)")
        return false
    }
}

/// Dispatches `runProcessSync` on a background queue. Non-blocking
/// helper for actions that fire-and-forget a single shell command.
func runProcessAsync(
    executable: String,
    arguments: [String],
    label: String,
    currentDirectory: String? = nil
) {
    DispatchQueue.global(qos: .userInitiated).async {
        _ = runProcessSync(
            executable: executable,
            arguments: arguments,
            currentDirectory: currentDirectory,
            label: label
        )
    }
}

/// Atomically open-or-create + append data via `fopen "a"`. Used by the
/// log-time + write-to-file actions so each line lands as a single
/// atomic write to a fresh fd, without TOCTOU between exists-check and
/// write.
func appendToFile(atPath path: String, data: Data) throws {
    guard let fp = fopen(path, "a") else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
            NSLocalizedDescriptionKey: "Cannot open file for appending: \(path)"
        ])
    }
    defer { fclose(fp) }
    data.withUnsafeBytes { bytes in
        guard let base = bytes.baseAddress else { return }
        _ = fwrite(base, 1, bytes.count, fp)
    }
}

/// Process termination helper. Pulled out as a free function so it can be
/// called from both the @MainActor executor and nonisolated background
/// queues.
enum ProcessRunner {
    /// Best-effort termination of a child process. Sends SIGTERM, waits
    /// up to `gracePeriod` for the process to exit, then sends SIGKILL.
    /// Returns true if the process actually exited within the grace
    /// window (SIGTERM was sufficient); false if SIGKILL was required.
    @discardableResult
    static func terminate(
        _ process: Process,
        label: String,
        gracePeriod: TimeInterval = NotificationActionRuntime.processKillGracePeriod
    ) -> Bool {
        guard process.isRunning else { return true }
        Log.warn("\(label): sending SIGTERM (timeout escalation)")
        process.terminate()

        let pollIntervalMs = 50
        let pollCount = max(1, Int((gracePeriod * 1000.0) / Double(pollIntervalMs)))
        for _ in 0 ..< pollCount {
            if !process.isRunning { return true }
            Thread.sleep(forTimeInterval: Double(pollIntervalMs) / 1000.0)
        }

        guard process.isRunning else { return true }
        Log.warn("\(label): SIGTERM ignored, sending SIGKILL after \(gracePeriod)s")
        kill(process.processIdentifier, SIGKILL)
        return false
    }
}

/// Outbound HTTP for notification actions. Routes through a dedicated
/// `URLSession` instead of `URLSession.shared` so the webhook / Slack /
/// Discord paths get explicit timeouts and don't share connection
/// limits with the rest of the app.
enum NotificationActionHTTP {
    /// 15 seconds for the initial request, 30 seconds total per resource
    /// (covers slow webhook responders without dragging on if the remote
    /// is dead). 6 concurrent outbound connections is plenty for the
    /// throughput of notification action HTTP.
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpMaximumConnectionsPerHost = 6
        // Don't pollute the shared cookie storage with whatever a
        // webhook endpoint sets.
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()
}
