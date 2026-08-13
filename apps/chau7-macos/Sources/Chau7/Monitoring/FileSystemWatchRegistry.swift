import Darwin
import Foundation

/// Shares O_EVTONLY dispatch sources for identical canonical paths and event
/// masks. Each subscriber still receives callbacks on its own state queue.
final class FileSystemWatchRegistry {
    static let shared = FileSystemWatchRegistry()

    final class Subscription {
        private let lock = NSLock()
        private weak var registry: FileSystemWatchRegistry?
        private let key: WatchKey
        private let id: UUID
        private var isCancelled = false

        fileprivate init(registry: FileSystemWatchRegistry, key: WatchKey, id: UUID) {
            self.registry = registry
            self.key = key
            self.id = id
        }

        func cancel() {
            lock.lock()
            guard !isCancelled else {
                lock.unlock()
                return
            }
            isCancelled = true
            lock.unlock()
            registry?.cancel(key: key, id: id)
        }

        deinit {
            cancel()
        }
    }

    fileprivate struct WatchKey: Hashable {
        let path: String
    }

    private struct Subscriber {
        let eventMask: DispatchSource.FileSystemEvent
        let callbackQueue: DispatchQueue
        let handler: (DispatchSource.FileSystemEvent) -> Void
    }

    private final class Entry {
        let source: DispatchSourceFileSystemObject
        var subscribers: [UUID: Subscriber]

        init(source: DispatchSourceFileSystemObject, subscribers: [UUID: Subscriber]) {
            self.source = source
            self.subscribers = subscribers
        }
    }

    private let queue: DispatchQueue
    private var entries: [WatchKey: Entry] = [:]

    init(label: String = "com.chau7.filesystem-watch-registry") {
        self.queue = DispatchQueue(label: label, qos: .utility)
    }

    func watch(
        url: URL,
        eventMask: DispatchSource.FileSystemEvent,
        callbackQueue: DispatchQueue,
        handler: @escaping (DispatchSource.FileSystemEvent) -> Void
    ) -> Subscription? {
        let canonicalPath = Self.canonicalPath(for: url)
        let key = WatchKey(path: canonicalPath)

        return queue.sync {
            let id = UUID()
            let subscriber = Subscriber(
                eventMask: eventMask,
                callbackQueue: callbackQueue,
                handler: handler
            )
            if let entry = entries[key] {
                entry.subscribers[id] = subscriber
                return Subscription(registry: self, key: key, id: id)
            }

            let descriptor = Darwin.open(canonicalPath, O_EVTONLY)
            guard descriptor >= 0 else { return nil }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .delete, .rename],
                queue: queue
            )
            let entry = Entry(source: source, subscribers: [id: subscriber])
            source.setEventHandler { [weak entry] in
                guard let entry else { return }
                let flags = source.data
                for subscriber in entry.subscribers.values {
                    let matchingFlags = flags.intersection(subscriber.eventMask)
                    guard !matchingFlags.isEmpty else { continue }
                    subscriber.callbackQueue.async {
                        subscriber.handler(matchingFlags)
                    }
                }
            }
            source.setCancelHandler {
                Darwin.close(descriptor)
            }
            entries[key] = entry
            source.resume()
            return Subscription(registry: self, key: key, id: id)
        }
    }

    func activeWatchCountForTesting() -> Int {
        queue.sync { entries.count }
    }

    func subscriptionCountForTesting() -> Int {
        queue.sync { entries.values.reduce(0) { $0 + $1.subscribers.count } }
    }

    func activePathsForTesting() -> [String] {
        queue.sync { entries.keys.map(\.path).sorted() }
    }

    func drainForTesting() {
        queue.sync {}
    }

    static func nearestExistingParent(
        of targetURL: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        var candidate = targetURL.deletingLastPathComponent().standardizedFileURL
        while true {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate.resolvingSymlinksInPath().standardizedFileURL
            }
            let next = candidate.deletingLastPathComponent().standardizedFileURL
            if next.path == candidate.path { return nil }
            candidate = next
        }
    }

    private func cancel(key: WatchKey, id: UUID) {
        queue.async { [weak self] in
            guard let self, let entry = entries[key] else { return }
            entry.subscribers.removeValue(forKey: id)
            if entry.subscribers.isEmpty {
                entries.removeValue(forKey: key)
                entry.source.cancel()
            }
        }
    }

    private static func canonicalPath(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
