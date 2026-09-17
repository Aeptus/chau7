import Foundation

/// Keeps all PTY writes (including protocol replies and destruction) ordered
/// off the UI thread. Only one clipboard reply may be queued/in flight: the
/// drain loop can observe the same pending OSC 52 request on several ticks.
public final class TerminalWriteQueue: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.chau7.pty-write", qos: .userInitiated)
    private let lock = NSLock()
    private var clipboardReplyPending = false

    public init() {}

    public var hasPendingClipboardReply: Bool {
        lock.lock()
        defer { lock.unlock() }
        return clipboardReplyPending
    }

    public func async(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    @discardableResult
    public func enqueueClipboardReply(_ work: @escaping @Sendable () -> Void) -> Bool {
        lock.lock()
        guard !clipboardReplyPending else { lock.unlock()
            return false
        }
        clipboardReplyPending = true
        lock.unlock()
        queue.async { [self] in
            defer {
                lock.lock()
                clipboardReplyPending = false
                lock.unlock()
            }
            work()
        }
        return true
    }

    /// Refuse oversized replies rather than queueing unbounded clipboard copies
    /// or returning a silently truncated value. OSC 52 permits an empty reply.
    public static func boundedClipboardText(_ text: String, maxBytes: Int = 1_048_576) -> String {
        guard maxBytes >= 0, text.utf8.count <= maxBytes else { return "" }
        return text
    }
}
