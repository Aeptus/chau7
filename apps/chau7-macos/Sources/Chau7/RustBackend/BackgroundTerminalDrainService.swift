import Foundation

/// Shared service that drains PTY buffers for background (non-interactive) terminal views.
/// Replaces per-tab drain threads with a single timer that polls all registered views
/// non-blocking. This reduces 26 threads to 1 timer for 26 background tabs.
final class BackgroundTerminalDrainService {
    static let shared = BackgroundTerminalDrainService()

    private let queue = DispatchQueue(label: "com.chau7.background-drain", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var views: [WeakTerminalView] = []
    private let lock = NSLock()

    private struct WeakTerminalView {
        weak var view: RustTerminalView?
    }

    private init() {}

    /// Register a terminal view for background PTY draining.
    func register(_ view: RustTerminalView) {
        lock.lock()
        defer { lock.unlock() }
        views.removeAll { $0.view == nil || $0.view === view }
        views.append(WeakTerminalView(view: view))
        if timer == nil { startTimer() }
    }

    /// Unregister a terminal view.
    func unregister(_ view: RustTerminalView) {
        lock.lock()
        defer { lock.unlock() }
        views.removeAll { $0.view == nil || $0.view === view }
        if views.isEmpty { stopTimer() }
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .seconds(1))
        t.setEventHandler { [weak self] in self?.drainAll() }
        t.resume()
        timer = t
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func drainAll() {
        lock.lock()
        views.removeAll { $0.view == nil }
        let snapshot = views.compactMap { $0.view }
        if snapshot.isEmpty {
            stopTimer()
            lock.unlock()
            return
        }
        lock.unlock()

        for view in snapshot {
            guard let rust = view.rustTerminal else { continue }

            // Poll non-blocking on the background queue.
            view.terminalPollAccessLock.lock()
            let changed = rust.poll(timeout: 0)

            guard changed else {
                view.terminalPollAccessLock.unlock()
                continue
            }

            // Release the lock before dispatching to main — holding it across
            // main.sync would deadlock if a queued pollAndSync is waiting for
            // the same lock on the main thread. Re-acquire on main to protect
            // processTerminalStateAfterPollLocked from concurrent poll/activation.
            view.terminalPollAccessLock.unlock()

            DispatchQueue.main.async { [weak view] in
                guard let view, let rust = view.rustTerminal else { return }
                view.terminalPollAccessLock.lock()
                defer { view.terminalPollAccessLock.unlock() }
                _ = view.processTerminalStateAfterPollLocked(rust: rust, changed: true)
                view.onBufferChanged?()
            }
        }
    }
}
