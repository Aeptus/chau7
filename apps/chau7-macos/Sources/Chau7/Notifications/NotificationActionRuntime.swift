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
        for _ in 0..<pollCount {
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
