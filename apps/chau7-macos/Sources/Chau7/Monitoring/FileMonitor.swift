import Foundation
import Darwin

final class FileMonitor {
    let url: URL
    private var descriptor: CInt = -1
    private var source: DispatchSourceFileSystemObject?
    private let queue: DispatchQueue
    private let onChange: () -> Void

    /// Reopen backoff after a failed open (path momentarily gone during an
    /// atomic replace or directory recreation). Watchdogs retry until told
    /// to stop — a single failed reopen used to kill monitoring permanently.
    private var retryDelay: TimeInterval = FileMonitor.initialRetryDelay
    private static let initialRetryDelay: TimeInterval = 0.2
    private static let maxRetryDelay: TimeInterval = 5.0
    private var isStopped = false

    init(url: URL, queue: DispatchQueue = DispatchQueue(label: "com.chau7.filemonitor"), onChange: @escaping () -> Void) {
        self.url = url
        self.queue = queue
        self.onChange = onChange
    }

    /// All monitor state is confined to the private queue — the event/cancel
    /// handlers run there, and rename/delete re-arms re-enter start there.
    func start() {
        queue.async { [self] in startOnQueue() }
    }

    func stop() {
        queue.async { [self] in stopOnQueue(markStopped: true) }
    }

    private func startOnQueue() {
        stopOnQueue(markStopped: false)
        isStopped = false
        descriptor = open(url.path, O_EVTONLY)
        guard descriptor != -1 else {
            scheduleRetry()
            return
        }
        retryDelay = Self.initialRetryDelay

        // Capture the fd by value so the cancel handler always closes the
        // correct descriptor, even if start() is called again before the
        // cancel handler fires.
        let fd = descriptor
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: queue
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self else { return }
            onChange()
            guard let source else { return }
            let flags = source.data
            if flags.contains(.rename) || flags.contains(.delete) {
                queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    guard let self, !isStopped else { return }
                    startOnQueue()
                }
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        self.source = source
        source.resume()
    }

    private func scheduleRetry() {
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, Self.maxRetryDelay)
        Log.trace("FileMonitor: open failed for \(url.path); retrying in \(delay)s")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !isStopped else { return }
            startOnQueue()
        }
    }

    private func stopOnQueue(markStopped: Bool) {
        if markStopped { isStopped = true }
        if let source {
            // The cancel handler owns close(fd) — no double-close race.
            source.cancel()
            self.source = nil
        } else if descriptor != -1 {
            // No source was created (e.g. open succeeded but source setup failed).
            close(descriptor)
        }
        descriptor = -1
    }
}
