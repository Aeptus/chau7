import Foundation

/// Serializes terminal shell launches at startup to avoid 27 simultaneous
/// zsh processes competing for CPU/disk. The selected tab starts immediately,
/// all others queue and launch one-by-one after the previous one has produced
/// its first PTY output or timed out.
final class TerminalStartupQueue {
    static let shared = TerminalStartupQueue()

    private var queue: [(work: () -> Void, label: String)] = []
    private var isRunning = false
    private var currentTimeout: DispatchWorkItem?
    private let maxWaitPerTab: TimeInterval = 2.0

    private init() {}

    /// Execute immediately if nothing is queued, otherwise enqueue.
    /// Priority items (selected tabs) skip the queue.
    func enqueue(priority: Bool, label: String, work: @escaping () -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))

        if priority || !isRunning {
            isRunning = true
            work()
            return
        }

        queue.append((work: work, label: label))
    }

    /// Signal that the current terminal produced its first output.
    /// Starts the next queued terminal.
    func currentTerminalReady() {
        dispatchPrecondition(condition: .onQueue(.main))
        currentTimeout?.cancel()
        currentTimeout = nil
        startNext()
    }

    private func startNext() {
        guard !queue.isEmpty else {
            isRunning = false
            return
        }

        let next = queue.removeFirst()
        Log.info("TerminalStartupQueue: launching \(next.label) (\(queue.count) remaining)")
        next.work()

        // Safety timeout — don't let a hung shell block the entire queue
        let timeout = DispatchWorkItem { [weak self] in
            Log.warn("TerminalStartupQueue: timeout waiting for \(next.label), advancing queue")
            self?.startNext()
        }
        currentTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + maxWaitPerTab, execute: timeout)
    }
}
