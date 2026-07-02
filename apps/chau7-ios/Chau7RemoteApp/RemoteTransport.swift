import Foundation
import Chau7Core
import os

private let log = Logger(subsystem: "ch7", category: "RemoteTransport")

/// Owns the relay WebSocket: the task itself, the generation counter that
/// invalidates stale async work after a reconnect, the strictly-ordered
/// receive pump, inbound rate limiting, and raw sends.
///
/// Extracted from `RemoteClient` (C6): the transport knows nothing about
/// crypto, frames, or session state — it delivers raw message data (tagged
/// with the generation it was received under) and reports receive failures.
/// The receive pump awaits `onMessage` before issuing the next receive, so
/// message processing stays strictly FIFO even when the handler offloads
/// decryption to a detached task.
@MainActor
final class RemoteTransport {

    /// Bumped on every close; async work captures the generation it started
    /// under and re-checks it after each suspension point.
    private(set) var generation: UInt64 = 0

    private var webSocketTask: URLSessionWebSocketTask?
    private var frameRateLimiter = RemoteFrameRateLimiter()
    private var lastThrottleLogAt: Date?

    /// Awaited per message: the pump does not issue the next receive until
    /// the handler returns. Receives the raw data and the generation the
    /// message arrived under.
    var onMessage: (@MainActor (Data, UInt64) async -> Void)?
    /// A receive failure for the current generation (stale-generation
    /// failures are swallowed — the socket they belonged to is gone).
    var onFailure: (@MainActor (Error) -> Void)?

    var isOpen: Bool {
        webSocketTask != nil
    }

    /// Open a socket for `request`, closing any existing one first, and
    /// start the receive pump.
    func open(request: URLRequest) {
        close()
        let task = URLSession.shared.webSocketTask(with: request)
        webSocketTask = task
        task.resume()
        listen()
    }

    /// Cancel the socket (if any) and invalidate the generation. Idempotent.
    func close() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        generation &+= 1
    }

    /// Send raw bytes. Returns false immediately when no socket is open;
    /// otherwise the completion reports the async send outcome (the error's
    /// description on failure, for telemetry).
    @discardableResult
    func send(_ data: Data, completion: (@MainActor (Bool, String?) -> Void)? = nil) -> Bool {
        guard let webSocketTask else { return false }
        webSocketTask.send(.data(data)) { error in
            if let error {
                log.error("WebSocket send failed: \(error.localizedDescription)")
                Task { @MainActor in
                    completion?(false, error.localizedDescription)
                }
            } else if let completion {
                Task { @MainActor in
                    completion(true, nil)
                }
            }
        }
        return true
    }

    // MARK: - Receive pump

    private func listen() {
        let generation = self.generation
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .failure(let error):
                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation else { return }
                    log.error("WebSocket receive failed: \(error.localizedDescription)")
                    self.onFailure?(error)
                }
            case .success(let msg):
                let data: Data
                switch msg {
                case .data(let frameData):
                    data = frameData
                case .string(let text):
                    data = Data(text.utf8)
                @unknown default:
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == generation else { return }
                        self.listen()
                    }
                    return
                }

                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation else { return }
                    await self.onMessage?(data, generation)
                    guard self.generation == generation else { return }
                    if self.frameRateLimiter.allow() {
                        self.listen()
                    } else {
                        // Suspected flood: read more slowly instead of dropping
                        // data, applying backpressure to a hostile relay.
                        self.noteThrottle()
                        Task { @MainActor [weak self] in
                            try? await Task.sleep(for: .milliseconds(50))
                            guard let self, self.generation == generation else { return }
                            self.listen()
                        }
                    }
                }
            }
        }
    }

    private func noteThrottle() {
        let now = Date()
        if let last = lastThrottleLogAt, now.timeIntervalSince(last) < 5 { return }
        lastThrottleLogAt = now
        log.warning("Inbound frame rate throttled (possible relay flood)")
    }
}
