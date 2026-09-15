import Chau7Core
import Foundation

final class FileMonitor {
    let url: URL

    private let queue: DispatchQueue
    private let onChange: () -> Void
    private let retryPolicy: FileObservationRetryPolicy
    private let watchRegistry: FileSystemWatchRegistry
    private let clock: () -> TimeInterval

    private var targetWatch: FileSystemWatchRegistry.Subscription?
    private var parentWatch: FileSystemWatchRegistry.Subscription?
    private var parentWatchURL: URL?
    private var retryWorkItem: DispatchWorkItem?
    private var retryAttempt = 0
    private var retryStartedAt: TimeInterval = 0
    private var isRunning = false

    init(
        url: URL,
        queue: DispatchQueue = DispatchQueue(label: "com.chau7.filemonitor", qos: .utility),
        retryPolicy: FileObservationRetryPolicy = .default,
        watchRegistry: FileSystemWatchRegistry = .shared,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        onChange: @escaping () -> Void
    ) {
        self.url = url
        self.queue = queue
        self.retryPolicy = retryPolicy
        self.watchRegistry = watchRegistry
        self.clock = clock
        self.onChange = onChange
    }

    /// Monitoring state and callbacks are confined to `queue`.
    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            stopOnQueue(markStopped: false)
            isRunning = true
            beginRecoveryWindow()
            armTargetOnQueue()
        }
    }

    func stop() {
        queue.async { [self] in stopOnQueue(markStopped: true) }
    }

    deinit {
        retryWorkItem?.cancel()
        targetWatch?.cancel()
        parentWatch?.cancel()
    }

    private func beginRecoveryWindow() {
        retryStartedAt = clock()
        retryAttempt = 0
        retryWorkItem?.cancel()
        retryWorkItem = nil
    }

    private func armTargetOnQueue() {
        guard isRunning else { return }
        targetWatch?.cancel()
        targetWatch = watchRegistry.watch(
            url: url,
            eventMask: [.write, .delete, .rename],
            callbackQueue: queue
        ) { [weak self] flags in
            guard let self, isRunning else { return }
            onChange()
            if flags.contains(.rename) || flags.contains(.delete) {
                targetWatch?.cancel()
                targetWatch = nil
                beginRecoveryWindow()
                scheduleTargetAttempt(after: retryPolicy.replacementDelay)
                armNearestExistingParentOnQueue()
            }
        }

        guard targetWatch != nil else {
            handleMissingTargetOnQueue()
            return
        }

        retryWorkItem?.cancel()
        retryWorkItem = nil
        parentWatch?.cancel()
        parentWatch = nil
        parentWatchURL = nil
        retryAttempt = 0
    }

    private func handleMissingTargetOnQueue() {
        guard isRunning else { return }
        if armNearestExistingParentOnQueue() { return }
        let elapsed = max(0, clock() - retryStartedAt)
        guard let delay = retryPolicy.delay(forAttempt: retryAttempt, elapsed: elapsed) else {
            retryWorkItem?.cancel()
            retryWorkItem = nil
            Log.trace("FileMonitor: active retries exhausted for \(url.path); waiting for parent event")
            return
        }
        retryAttempt += 1
        Log.trace("FileMonitor: open failed for \(url.path); retrying in \(delay)s")
        scheduleTargetAttempt(after: delay)
    }

    private func scheduleTargetAttempt(after delay: TimeInterval) {
        retryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, isRunning else { return }
            retryWorkItem = nil
            armTargetOnQueue()
        }
        retryWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    @discardableResult
    private func armNearestExistingParentOnQueue() -> Bool {
        guard isRunning,
              let parentURL = FileSystemWatchRegistry.nearestExistingParent(of: url) else { return false }
        if parentWatch != nil, parentWatchURL == parentURL { return false }

        parentWatch?.cancel()
        parentWatchURL = parentURL
        parentWatch = watchRegistry.watch(
            url: parentURL,
            eventMask: [.write, .delete, .rename],
            callbackQueue: queue
        ) { [weak self] flags in
            guard let self, isRunning else { return }
            if flags.contains(.delete) || flags.contains(.rename) {
                parentWatch?.cancel()
                parentWatch = nil
                parentWatchURL = nil
                armNearestExistingParentOnQueue()
                return
            }
            armTargetOnQueue()
            // Directory creation can arrive as a burst while an intermediate
            // hierarchy is still being assembled. If the target was absent
            // during the immediate handoff, make one delayed attempt scoped to
            // this parent event. This closes the race without restarting the
            // bounded recovery window or restoring permanent polling.
            if targetWatch == nil {
                scheduleTargetAttempt(after: retryPolicy.replacementDelay)
            }
        }

        // Close the handoff race where the target appears after the failed
        // open but before the newly discovered parent watch is installed.
        if parentWatch != nil {
            armTargetOnQueue()
            return true
        }
        return false
    }

    private func stopOnQueue(markStopped: Bool) {
        if markStopped { isRunning = false }
        retryWorkItem?.cancel()
        retryWorkItem = nil
        targetWatch?.cancel()
        targetWatch = nil
        parentWatch?.cancel()
        parentWatch = nil
        parentWatchURL = nil
    }
}
