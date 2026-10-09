import Foundation

/// Event-driven PTY drain for a locally active or remotely viewed terminal.
///
/// Replaces the free-running CVDisplayLink with a blocking-poll loop:
/// - Calls `rust.pollEvents(timeout:)` which blocks until PTY data arrives or timeout
/// - On data: dispatches metadata processing and, when needed, rendering to main
/// - On timeout: loops silently (near-zero CPU)
///
/// One instance may be active per live presentation surface, plus at most one
/// hidden terminal selected by the foreground remote client. Other background
/// tabs use `BackgroundTerminalDrainService` instead.
final class TerminalEventDrain {

    /// Interval (ms) for the blocking poll. The thread sleeps in the kernel
    /// for up to this long between checks. 200ms balances responsiveness
    /// (worst-case latency for unsolicited output like a background build)
    /// against minimal kernel scheduling overhead.
    private static let pollTimeoutMs: UInt32 = 200

    /// Guards `thread` and `generation`. The old design used a plain
    /// `cancelled` Bool written on main and read on the drain thread —
    /// formally UB — and `start()`'s `stop(); cancelled = false` sequence
    /// could resurrect an old runloop still inside its final blocking poll.
    /// Each run now captures its generation; bumping the counter (start or
    /// stop) invalidates every previous loop without any shared flag reset.
    private let stateLock = NSLock()
    private var thread: Thread?
    private var generation: UInt64 = 0

    /// Coalesce gate: when output is heavy, `rust.pollEvents(timeout:)` returns
    /// immediately and the loop spins, producing 100+ `DispatchQueue.main.async`
    /// calls per second. The main queue saturates with redundant
    /// `handleEventDrainData` work and user input dispatches queue behind it,
    /// causing the multi-second input latency observed in the Mockup-Claude
    /// streaming-output diagnosis (P5).
    ///
    /// Cap concurrency at one in-flight handler. While the handler is on the
    /// main queue, additional drain wakes drop their dispatch. The in-flight
    /// handler's non-blocking `rust.pollEvents(timeout: 0)` at the top of
    /// `handleEventDrainData` picks up everything that arrived since the
    /// drain's blocking poll returned, so no data is lost.
    private let coalesceLock = NSLock()
    private var hasInFlightHandler = false
    private var pendingFlags = TerminalPollEventFlags()
    private var pendingGridChangeAtUptimeNanoseconds: UInt64?

    /// Start draining PTY events for the given terminal view.
    /// Stops any previous drain first.
    func start(for view: RustTerminalView) {
        let viewId = view.viewId

        stateLock.lock()
        generation += 1
        let myGeneration = generation
        let thread = Thread { [weak self, weak view] in
            self?.runLoop(view: view, viewId: viewId, generation: myGeneration)
        }
        thread.qualityOfService = .userInitiated
        thread.name = "com.chau7.terminal-event-drain-\(viewId)"
        self.thread = thread
        // Fresh run: drop any backoff state so a restarted drain still polls at
        // full rate while its terminal is being created.
        terminalMissingBackoffPasses = 0
        stateLock.unlock()

        thread.start()
        Log.info("TerminalEventDrain: started for view \(viewId)")
    }

    /// Stop the drain loop. Safe to call multiple times.
    func stop() {
        stateLock.lock()
        generation += 1
        thread = nil
        stateLock.unlock()
    }

    /// Whether the drain is currently running.
    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return thread != nil
    }

    // MARK: - Private

    private func isCurrent(_ gen: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return generation == gen
    }

    /// Consecutive passes that found no Rust terminal. Reset as soon as one
    /// appears. Only touched from the drain thread, and reset when a new run
    /// starts, so no lock is needed.
    private var terminalMissingBackoffPasses = 0

    /// Startup responsiveness comes from the first few passes; after that a
    /// drain that still has no terminal is almost certainly a failed creation,
    /// so the interval converges to `maxPollTimeoutSeconds` and the thread
    /// costs ~0.2 wakeups/second instead of 20.
    ///
    /// Returns a `TimeInterval`; pure so the curve is testable.
    static func pollTimeoutInterval(
        afterMissingPasses passes: Int,
        initialSeconds: TimeInterval = 0.05,
        maxSeconds: TimeInterval = 0.25
    ) -> TimeInterval {
        guard passes > 1 else { return initialSeconds }
        return min(initialSeconds * pow(2, Double(passes - 1)), maxSeconds)
    }

    private func runLoop(view: RustTerminalView?, viewId: UInt64, generation: UInt64) {
        while isCurrent(generation) {
            guard let view = view, !view.isBeingDeallocated else {
                Log.trace("TerminalEventDrain[\(viewId)]: view gone, exiting")
                return
            }
            guard let rust = view.rustTerminal else {
                // Terminal not created yet. Back off instead of spinning: the
                // previous fixed 50 ms sleep meant a drain started for a view
                // whose terminal creation failed (and was never stopped) woke
                // 20x a second for the life of the view. Startup latency is
                // unaffected because `startEventDrain` is called after the
                // terminal exists, so the first pass hits this branch at most
                // for the moment between "view allocated" and "terminal ready".
                terminalMissingBackoffPasses += 1
                let interval = Self.pollTimeoutInterval(afterMissingPasses: terminalMissingBackoffPasses)
                guard isCurrent(generation) else { return }
                Thread.sleep(forTimeInterval: interval)
                continue
            }
            terminalMissingBackoffPasses = 0

            // Block until the Rust pty-reader has processed new PTY data,
            // or the timeout elapses. This is the key efficiency win:
            // the thread sleeps in the kernel with zero CPU when idle.
            let flags = rust.pollEvents(timeout: Self.pollTimeoutMs)
            let gridChangeAt = flags.contains(.gridChanged)
                ? DispatchTime.now().uptimeNanoseconds
                : nil

            guard isCurrent(generation) else { return }

            if !flags.isEmpty {
                dispatchHandlerIfNotInFlight(
                    view: view,
                    flags: flags,
                    gridChangeAtUptimeNanoseconds: gridChangeAt
                )
            }
        }
        Log.trace("TerminalEventDrain[\(viewId)]: cancelled, exiting")
    }

    /// Dispatches `view.handleEventDrainData(drainFlags:)` to the main queue if no
    /// previous dispatch is still in flight; otherwise drops this wake.
    /// Pure coalescence — see `coalesceLock` doc for the rationale.
    private func dispatchHandlerIfNotInFlight(
        view: RustTerminalView,
        flags: TerminalPollEventFlags,
        gridChangeAtUptimeNanoseconds: UInt64?
    ) {
        coalesceLock.lock()
        let alreadyInFlight = hasInFlightHandler
        if !alreadyInFlight {
            hasInFlightHandler = true
        } else {
            pendingFlags.formUnion(flags)
            if let gridChangeAtUptimeNanoseconds {
                if let pending = pendingGridChangeAtUptimeNanoseconds {
                    pendingGridChangeAtUptimeNanoseconds = min(pending, gridChangeAtUptimeNanoseconds)
                } else {
                    pendingGridChangeAtUptimeNanoseconds = gridChangeAtUptimeNanoseconds
                }
            }
        }
        coalesceLock.unlock()

        guard !alreadyInFlight else { return }

        runHandler(
            view: view,
            flags: flags,
            gridChangeAtUptimeNanoseconds: gridChangeAtUptimeNanoseconds
        )
    }

    private func runHandler(
        view: RustTerminalView,
        flags: TerminalPollEventFlags,
        gridChangeAtUptimeNanoseconds: UInt64?
    ) {
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self else { return }
            guard let view, !view.isBeingDeallocated else {
                finishHandler(view: nil)
                return
            }
            let eventDispatchWaitMilliseconds = gridChangeAtUptimeNanoseconds.map { eventTime in
                let now = DispatchTime.now().uptimeNanoseconds
                guard now >= eventTime else { return 0.0 }
                return Double(now - eventTime) / 1_000_000
            }
            view.handleEventDrainData(
                drainFlags: flags,
                eventDispatchWaitMilliseconds: eventDispatchWaitMilliseconds
            )
            finishHandler(view: view)
        }
    }

    private func finishHandler(view: RustTerminalView?) {
        coalesceLock.lock()
        let followUpFlags = isRunning && view != nil ? pendingFlags : TerminalPollEventFlags()
        let followUpGridChangeAt = followUpFlags.isEmpty ? nil : pendingGridChangeAtUptimeNanoseconds
        if !followUpFlags.isEmpty {
            pendingFlags = []
            pendingGridChangeAtUptimeNanoseconds = nil
        } else {
            hasInFlightHandler = false
            pendingFlags = []
            pendingGridChangeAtUptimeNanoseconds = nil
        }
        coalesceLock.unlock()

        if !followUpFlags.isEmpty, let view {
            runHandler(
                view: view,
                flags: followUpFlags,
                gridChangeAtUptimeNanoseconds: followUpGridChangeAt
            )
        }
    }
}
