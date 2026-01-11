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

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: queue
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self else { return }
            self.onChange()
            guard let source else { return }
            let flags = source.data
            if flags.contains(.rename) || flags.contains(.delete) {
                self.queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.start()
                }
            }
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.descriptor != -1 {
                close(self.descriptor)
                self.descriptor = -1
            }
        }
        self.source = source
        source.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
        if descriptor != -1 {
            close(descriptor)
            descriptor = -1
        }
    }
}
