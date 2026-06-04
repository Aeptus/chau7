import Foundation

/// Event-driven PTY drain for the active (selected) terminal.
///
/// Replaces the free-running CVDisplayLink with a blocking-poll loop:
/// - Calls `rust.pollEvents(timeout:)` which blocks until PTY data arrives or timeout
/// - On data: dispatches metadata processing and, when needed, rendering to main
/// - On timeout: loops silently (near-zero CPU)
///
/// One instance may be active per live presentation surface. Background tabs
/// use `BackgroundTerminalDrainService` instead.
final class TerminalEventDrain {

    /// Interval (ms) for the blocking poll. The thread sleeps in the kernel
    /// for up to this long between checks. 200ms balances responsiveness
    /// (worst-case latency for unsolicited output like a background build)
    /// against minimal kernel scheduling overhead.
    private static let pollTimeoutMs: UInt32 = 200

    private var thread: Thread?
    private var cancelled = false

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

    /// Start draining PTY events for the given terminal view.
    /// Stops any previous drain first.
    func start(for view: RustTerminalView) {
        stop()
        cancelled = false

        let viewId = view.viewId
        let thread = Thread { [weak self, weak view] in
            self?.runLoop(view: view, viewId: viewId)
        }
        thread.qualityOfService = .userInitiated
        thread.name = "com.chau7.terminal-event-drain-\(viewId)"
        thread.start()
        self.thread = thread

        Log.info("TerminalEventDrain: started for view \(viewId)")
    }

    /// Stop the drain loop. Safe to call multiple times.
    func stop() {
        guard thread != nil else { return }
        cancelled = true
        thread = nil
    }

    /// Whether the drain is currently running.
    var isRunning: Bool {
        thread != nil && !cancelled
    }

    // MARK: - Private

    private func runLoop(view: RustTerminalView?, viewId: UInt64) {
        while !cancelled {
            guard let view = view, !view.isBeingDeallocated else {
                Log.trace("TerminalEventDrain[\(viewId)]: view gone, exiting")
                return
            }
            guard let rust = view.rustTerminal else {
                // Terminal not started yet — wait and retry
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }

            // Block until the Rust pty-reader has processed new PTY data,
            // or the timeout elapses. This is the key efficiency win:
            // the thread sleeps in the kernel with zero CPU when idle.
            let flags = rust.pollEvents(timeout: Self.pollTimeoutMs)

            guard !cancelled else { return }

            if !flags.isEmpty {
                dispatchHandlerIfNotInFlight(view: view, flags: flags)
            }
        }
        Log.trace("TerminalEventDrain[\(viewId)]: cancelled, exiting")
    }

    /// Dispatches `view.handleEventDrainData(drainGridChanged:)` to the main queue if no
    /// previous dispatch is still in flight; otherwise drops this wake.
    /// Pure coalescence — see `coalesceLock` doc for the rationale.
    private func dispatchHandlerIfNotInFlight(view: RustTerminalView, flags: TerminalPollEventFlags) {
        coalesceLock.lock()
        let alreadyInFlight = hasInFlightHandler
        if !alreadyInFlight {
            hasInFlightHandler = true
        } else {
            pendingFlags.formUnion(flags)
        }
        coalesceLock.unlock()

        guard !alreadyInFlight else { return }

        runHandler(view: view, flags: flags)
    }

    private func runHandler(view: RustTerminalView, flags: TerminalPollEventFlags) {
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self else { return }
            guard let view, !view.isBeingDeallocated else {
                finishHandler(view: nil)
                return
            }
            view.handleEventDrainData(drainGridChanged: flags.contains(.gridChanged))
            finishHandler(view: view)
        }
    }

    private func finishHandler(view: RustTerminalView?) {
        coalesceLock.lock()
        let followUpFlags = !cancelled && view != nil ? pendingFlags : TerminalPollEventFlags()
        if !followUpFlags.isEmpty {
            pendingFlags = []
        } else {
            hasInFlightHandler = false
            pendingFlags = []
        }
        coalesceLock.unlock()

        if !followUpFlags.isEmpty, let view {
            runHandler(view: view, flags: followUpFlags)
        }
    }
}
