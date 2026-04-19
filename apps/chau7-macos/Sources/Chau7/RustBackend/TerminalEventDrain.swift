import Foundation

/// Event-driven PTY drain for the active (selected) terminal.
///
/// Replaces the free-running CVDisplayLink with a blocking-poll loop:
/// - Calls `rust.poll(timeout:)` which blocks until PTY data arrives or timeout
/// - On data: dispatches processing + rendering to main thread
/// - On timeout: loops silently (near-zero CPU)
///
/// Only one instance should be active at a time (the selected tab).
/// Background tabs use `BackgroundTerminalDrainService` instead.
final class TerminalEventDrain {

    /// Interval (ms) for the blocking poll. The thread sleeps in the kernel
    /// for up to this long between checks. 200ms balances responsiveness
    /// (worst-case latency for unsolicited output like a background build)
    /// against minimal kernel scheduling overhead.
    private static let pollTimeoutMs: UInt32 = 200

    private var thread: Thread?
    private var cancelled = false

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
            let changed = rust.poll(timeout: Self.pollTimeoutMs)

            guard !cancelled else { return }

            if changed {
                DispatchQueue.main.async { [weak view] in
                    guard let view = view, !view.isBeingDeallocated else { return }
                    view.handleEventDrainData()
                }
            }
        }
        Log.trace("TerminalEventDrain[\(viewId)]: cancelled, exiting")
    }
}
