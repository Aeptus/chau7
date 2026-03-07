import Foundation
import Darwin

final class FileMonitor {
    let url: URL
    private var descriptor: CInt = -1
    private var source: DispatchSourceFileSystemObject?
    private let queue: DispatchQueue
    private let onChange: () -> Void

    init(url: URL, queue: DispatchQueue = DispatchQueue(label: "com.chau7.filemonitor"), onChange: @escaping () -> Void) {
        self.url = url
        self.queue = queue
        self.onChange = onChange
    }

    func start() {
        stop()
        descriptor = open(url.path, O_EVTONLY)
        guard descriptor != -1 else { return }

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
                    self?.start()
                }
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        self.source = source
        source.resume()
    }

    func stop() {
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
