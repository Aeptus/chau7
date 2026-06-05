import Foundation

/// Decides how often a background terminal view is polled, based on how long it has
/// been idle. Recently-active views are polled every tick; a view that keeps coming
/// back empty is polled progressively less often (down to once per `maxStride` ticks),
/// which cuts steady background CPU for dormant tabs while staying responsive when
/// output resumes (the idle streak resets on the first non-empty poll).
///
/// This is the low-risk, Swift-only step toward fully event-driven draining. The
/// eventual form watches a Rust-exposed readiness fd via `DispatchSource.makeReadSource`
/// so idle tabs cost nothing at all; that requires FFI + dylib changes and is tracked
/// as a follow-up. Pure and deterministic so the cadence is unit-tested.
enum BackgroundDrainBackoff {
    /// Poll every tick until this many consecutive empty polls have been observed.
    static let warmTicks = 3
    /// Deepest backoff: at most one poll per this many ticks.
    static let maxStride = 8

    /// Ticks between polls for a view with the given consecutive-idle streak.
    static func stride(forIdleStreak streak: Int) -> Int {
        guard streak >= warmTicks else { return 1 }
        return min(maxStride, streak - warmTicks + 2)
    }

    /// Whether a view with `idleStreak` should be polled on global tick `tick`.
    static func shouldPoll(idleStreak: Int, tick: Int) -> Bool {
        tick.isMultiple(of: stride(forIdleStreak: idleStreak))
    }
}

/// Shared service that drains PTY buffers for background (non-interactive) terminal views.
/// Replaces per-tab drain threads with a single timer that polls all registered views
/// non-blocking. This reduces 26 threads to 1 timer for 26 background tabs, and applies
/// `BackgroundDrainBackoff` so dormant tabs are polled less often than active ones.
final class BackgroundTerminalDrainService {
    static let shared = BackgroundTerminalDrainService()

    private let queue = DispatchQueue(label: "com.chau7.background-drain", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var views: [WeakTerminalView] = []
    private let lock = NSLock()

    /// Monotonic drain-tick counter and per-view consecutive-idle streaks. Both are
    /// touched only inside `drainAll` (on `queue`), so they need no extra locking.
    private var tickCount = 0
    private var idleStreakByView: [ObjectIdentifier: Int] = [:]

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

        tickCount += 1
        // Drop idle-streak state for views that have gone away.
        let liveIDs = Set(snapshot.map { ObjectIdentifier($0) })
        idleStreakByView = idleStreakByView.filter { liveIDs.contains($0.key) }

        for view in snapshot {
            let viewID = ObjectIdentifier(view)
            let idleStreak = idleStreakByView[viewID] ?? 0
            // Dormant views are polled less often (see BackgroundDrainBackoff).
            guard BackgroundDrainBackoff.shouldPoll(idleStreak: idleStreak, tick: tickCount) else {
                continue
            }
            guard let rust = view.rustTerminal else { continue }

            // Poll non-blocking on the background queue.
            view.terminalPollAccessLock.lock()
            let flags = rust.pollEvents(timeout: 0)

            guard !flags.isEmpty else {
                view.terminalPollAccessLock.unlock()
                idleStreakByView[viewID] = idleStreak + 1
                continue
            }
            idleStreakByView[viewID] = 0
            let gridChanged = flags.contains(.gridChanged)

            // Release the lock before dispatching to main — holding it across
            // main.sync would deadlock if a queued pollAndSync is waiting for
            // the same lock on the main thread. Re-acquire on main to protect
            // processTerminalStateAfterPollLocked from concurrent poll/activation.
            view.terminalPollAccessLock.unlock()

            DispatchQueue.main.async { [weak view] in
                guard let view, let rust = view.rustTerminal else { return }
                view.terminalPollAccessLock.lock()
                defer { view.terminalPollAccessLock.unlock() }
                _ = view.processTerminalStateAfterPollLocked(rust: rust, changed: gridChanged)
                if gridChanged {
                    view.onBufferChanged?()
                }
            }
        }
    }
}
