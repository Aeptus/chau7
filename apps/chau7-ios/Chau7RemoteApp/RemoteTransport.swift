import Chau7Core
import Foundation
import os

private let log = Logger(subsystem: "ch7", category: "RemoteTransport")

struct RemoteTerminalFrameIdentity: Equatable, Sendable, CustomStringConvertible {
    let transportGeneration: UInt64
    let sequence: UInt64

    var description: String {
        "\(transportGeneration):\(sequence)"
    }
}

/// Sequence-correlated timestamps for one terminal-output frame. The macOS
/// timestamps use wall time so they can cross the device boundary; every iOS
/// timestamp is captured in-process as the same frame advances toward display.
struct RemoteTerminalFrameTrace: Equatable, Sendable {
    let transportGeneration: UInt64
    let sequence: UInt64
    let tabID: UInt32
    let bytes: Int
    let macCapturedAtMicroseconds: UInt64?
    let macSentAtMicroseconds: UInt64?
    let iosReceivedAt: Date
    let iosAppliedAt: Date
    var engineAppliedAt: Date?
    var statePublishedAt: Date?
    var viewUpdatedAt: Date?
    var canvasDrawnAt: Date?
    var nextVSyncAt: Date?

    var identity: RemoteTerminalFrameIdentity {
        RemoteTerminalFrameIdentity(
            transportGeneration: transportGeneration,
            sequence: sequence
        )
    }

    var latency: RemoteTerminalFrameLatency {
        RemoteTerminalFrameLatency(
            macCaptureToSendMs: Self.milliseconds(
                fromMicroseconds: macCapturedAtMicroseconds,
                toMicroseconds: macSentAtMicroseconds
            ),
            estimatedMacSendToIOSReceiveMs: Self.milliseconds(
                fromMicroseconds: macSentAtMicroseconds,
                to: iosReceivedAt
            ),
            iosReceiveToApplyMs: Self.milliseconds(from: iosReceivedAt, to: iosAppliedAt),
            iosApplyToEngineMs: Self.milliseconds(from: iosAppliedAt, to: engineAppliedAt),
            engineToPublishMs: Self.milliseconds(from: engineAppliedAt, to: statePublishedAt),
            publishToViewMs: Self.milliseconds(from: statePublishedAt, to: viewUpdatedAt),
            viewToDrawMs: Self.milliseconds(from: viewUpdatedAt, to: canvasDrawnAt),
            drawToNextVSyncMs: Self.milliseconds(from: canvasDrawnAt, to: nextVSyncAt),
            estimatedMacCaptureToDrawMs: Self.milliseconds(
                fromMicroseconds: macCapturedAtMicroseconds,
                to: canvasDrawnAt
            ),
            estimatedMacCaptureToNextVSyncMs: Self.milliseconds(
                fromMicroseconds: macCapturedAtMicroseconds,
                to: nextVSyncAt
            )
        )
    }

    private static func milliseconds(from start: Date?, to end: Date?) -> Double? {
        guard let start, let end else { return nil }
        return max(0, end.timeIntervalSince(start) * 1000)
    }

    private static func milliseconds(fromMicroseconds start: UInt64?, toMicroseconds end: UInt64?) -> Double? {
        guard let start, let end else { return nil }
        return Double(end >= start ? end - start : 0) / 1000
    }

    private static func milliseconds(fromMicroseconds start: UInt64?, to end: Date?) -> Double? {
        guard let start, let end else { return nil }
        let endMicroseconds = UInt64(max(0, end.timeIntervalSince1970 * 1_000_000))
        return Double(endMicroseconds >= start ? endMicroseconds - start : 0) / 1000
    }
}

struct RemoteTerminalFrameLatency: Equatable, Sendable {
    let macCaptureToSendMs: Double?
    let estimatedMacSendToIOSReceiveMs: Double?
    let iosReceiveToApplyMs: Double?
    let iosApplyToEngineMs: Double?
    let engineToPublishMs: Double?
    let publishToViewMs: Double?
    let viewToDrawMs: Double?
    let drawToNextVSyncMs: Double?
    let estimatedMacCaptureToDrawMs: Double?
    let estimatedMacCaptureToNextVSyncMs: Double?
}

struct RemoteStreamingPerformanceSnapshot: Equatable {
    let frameCount: Int
    let admittedFrameCount: Int
    let decodeFailureCount: Int
    let decryptFailureCount: Int
    let outputFrameCount: Int
    let gridFrameCount: Int
    let helloFrameCount: Int
    let sessionReadyFrameCount: Int
    let tabInventoryFrameCount: Int
    let snapshotFrameCount: Int
    let bytes: Int
    let maxQueueAgeMs: Double
    let maxReceiveToApplyMs: Double
    let averageGridDecodeMs: Double
    let averagePublishMs: Double
    let supersededGridFrames: Int
    let outputRecoveryCount: Int
    let maxSenderBatchMs: Double
    let maxEstimatedCaptureToReceiveMs: Double
    let presentedFrameCount: Int
    let maxEstimatedMacSendToIOSReceiveMs: Double
    let maxIOSReceiveToApplyMs: Double
    let maxIOSApplyToEngineMs: Double
    let maxEngineToPublishMs: Double
    let maxPublishToViewMs: Double
    let maxViewToDrawMs: Double
    let maxDrawToNextVSyncMs: Double
    let maxEstimatedMacCaptureToDrawMs: Double
    let maxEstimatedMacCaptureToNextVSyncMs: Double
    let lastPresentedTraceIdentity: RemoteTerminalFrameIdentity?
    let lastPresentedBytes: Int
}

enum RemoteFrameAdmission: Equatable {
    case admitted
    case decodeFailed
    case decryptFailed
}

struct RemoteStreamingPerformanceWindow {
    private var startedAt: Date
    private var frameCount = 0
    private var admittedFrameCount = 0
    private var decodeFailureCount = 0
    private var decryptFailureCount = 0
    private var outputFrameCount = 0
    private var gridFrameCount = 0
    private var helloFrameCount = 0
    private var sessionReadyFrameCount = 0
    private var tabInventoryFrameCount = 0
    private var snapshotFrameCount = 0
    private var bytes = 0
    private var maxQueueAgeMs = 0.0
    private var maxReceiveToApplyMs = 0.0
    private var gridDecodeMs = 0.0
    private var gridDecodeCount = 0
    private var publishMs = 0.0
    private var publishCount = 0
    private var supersededGridFrames = 0
    private var outputRecoveryCount = 0
    private var maxSenderBatchMs = 0.0
    private var maxEstimatedCaptureToReceiveMs = 0.0
    private var presentedFrameCount = 0
    private var maxEstimatedMacSendToIOSReceiveMs = 0.0
    private var maxIOSReceiveToApplyMs = 0.0
    private var maxIOSApplyToEngineMs = 0.0
    private var maxEngineToPublishMs = 0.0
    private var maxPublishToViewMs = 0.0
    private var maxViewToDrawMs = 0.0
    private var maxDrawToNextVSyncMs = 0.0
    private var maxEstimatedMacCaptureToDrawMs = 0.0
    private var maxEstimatedMacCaptureToNextVSyncMs = 0.0
    private var lastPresentedTraceIdentity: RemoteTerminalFrameIdentity?
    private var lastPresentedBytes = 0

    init(startedAt: Date = Date()) {
        self.startedAt = startedAt
    }

    mutating func recordFrame(
        type: RemoteFrameType?,
        admission: RemoteFrameAdmission,
        bytes: Int,
        queueAgeMs: Double,
        receiveToApplyMs: Double,
        supersededGrids: Int
    ) {
        frameCount += 1
        self.bytes += bytes
        maxQueueAgeMs = max(maxQueueAgeMs, queueAgeMs)
        maxReceiveToApplyMs = max(maxReceiveToApplyMs, receiveToApplyMs)
        supersededGridFrames += supersededGrids
        switch admission {
        case .admitted:
            admittedFrameCount += 1
            switch type {
            case .output: outputFrameCount += 1
            case .terminalGridSnapshot: gridFrameCount += 1
            case .hello: helloFrameCount += 1
            case .sessionReady: sessionReadyFrameCount += 1
            case .tabList, .cachedTabList: tabInventoryFrameCount += 1
            case .snapshot: snapshotFrameCount += 1
            default: break
            }
        case .decodeFailed:
            decodeFailureCount += 1
        case .decryptFailed:
            decryptFailureCount += 1
        }
    }

    mutating func recordGridDecode(durationMs: Double) {
        gridDecodeMs += durationMs
        gridDecodeCount += 1
    }

    mutating func recordPublish(durationMs: Double) {
        publishMs += durationMs
        publishCount += 1
    }

    mutating func recordOutputTiming(senderBatchMs: Double, estimatedCaptureToReceiveMs: Double) {
        maxSenderBatchMs = max(maxSenderBatchMs, senderBatchMs)
        maxEstimatedCaptureToReceiveMs = max(maxEstimatedCaptureToReceiveMs, estimatedCaptureToReceiveMs)
    }

    mutating func recordOutputRecovery() {
        outputRecoveryCount += 1
    }

    mutating func recordPresentation(_ trace: RemoteTerminalFrameTrace) {
        let latency = trace.latency
        presentedFrameCount += 1
        maxEstimatedMacSendToIOSReceiveMs = max(
            maxEstimatedMacSendToIOSReceiveMs,
            latency.estimatedMacSendToIOSReceiveMs ?? 0
        )
        maxIOSReceiveToApplyMs = max(maxIOSReceiveToApplyMs, latency.iosReceiveToApplyMs ?? 0)
        maxIOSApplyToEngineMs = max(maxIOSApplyToEngineMs, latency.iosApplyToEngineMs ?? 0)
        maxEngineToPublishMs = max(maxEngineToPublishMs, latency.engineToPublishMs ?? 0)
        maxPublishToViewMs = max(maxPublishToViewMs, latency.publishToViewMs ?? 0)
        maxViewToDrawMs = max(maxViewToDrawMs, latency.viewToDrawMs ?? 0)
        maxDrawToNextVSyncMs = max(maxDrawToNextVSyncMs, latency.drawToNextVSyncMs ?? 0)
        maxEstimatedMacCaptureToDrawMs = max(
            maxEstimatedMacCaptureToDrawMs,
            latency.estimatedMacCaptureToDrawMs ?? 0
        )
        maxEstimatedMacCaptureToNextVSyncMs = max(
            maxEstimatedMacCaptureToNextVSyncMs,
            latency.estimatedMacCaptureToNextVSyncMs ?? 0
        )
        lastPresentedTraceIdentity = trace.identity
        lastPresentedBytes = trace.bytes
    }

    mutating func takeSnapshotIfDue(now: Date = Date(), interval: TimeInterval = 5) -> RemoteStreamingPerformanceSnapshot? {
        guard frameCount > 0, now.timeIntervalSince(startedAt) >= interval else { return nil }
        let snapshot = RemoteStreamingPerformanceSnapshot(
            frameCount: frameCount,
            admittedFrameCount: admittedFrameCount,
            decodeFailureCount: decodeFailureCount,
            decryptFailureCount: decryptFailureCount,
            outputFrameCount: outputFrameCount,
            gridFrameCount: gridFrameCount,
            helloFrameCount: helloFrameCount,
            sessionReadyFrameCount: sessionReadyFrameCount,
            tabInventoryFrameCount: tabInventoryFrameCount,
            snapshotFrameCount: snapshotFrameCount,
            bytes: bytes,
            maxQueueAgeMs: maxQueueAgeMs,
            maxReceiveToApplyMs: maxReceiveToApplyMs,
            averageGridDecodeMs: gridDecodeCount == 0 ? 0 : gridDecodeMs / Double(gridDecodeCount),
            averagePublishMs: publishCount == 0 ? 0 : publishMs / Double(publishCount),
            supersededGridFrames: supersededGridFrames,
            outputRecoveryCount: outputRecoveryCount,
            maxSenderBatchMs: maxSenderBatchMs,
            maxEstimatedCaptureToReceiveMs: maxEstimatedCaptureToReceiveMs,
            presentedFrameCount: presentedFrameCount,
            maxEstimatedMacSendToIOSReceiveMs: maxEstimatedMacSendToIOSReceiveMs,
            maxIOSReceiveToApplyMs: maxIOSReceiveToApplyMs,
            maxIOSApplyToEngineMs: maxIOSApplyToEngineMs,
            maxEngineToPublishMs: maxEngineToPublishMs,
            maxPublishToViewMs: maxPublishToViewMs,
            maxViewToDrawMs: maxViewToDrawMs,
            maxDrawToNextVSyncMs: maxDrawToNextVSyncMs,
            maxEstimatedMacCaptureToDrawMs: maxEstimatedMacCaptureToDrawMs,
            maxEstimatedMacCaptureToNextVSyncMs: maxEstimatedMacCaptureToNextVSyncMs,
            lastPresentedTraceIdentity: lastPresentedTraceIdentity,
            lastPresentedBytes: lastPresentedBytes
        )
        self = RemoteStreamingPerformanceWindow(startedAt: now)
        return snapshot
    }
}

struct RemoteInboundMessage: Sendable, Equatable {
    let data: Data
    let generation: UInt64
    let receivedAt: Date
    let queueDepthAtEnqueue: Int
    var suppressOutputApplication: Bool

    var isGridSnapshot: Bool {
        data.count > 1 && data[data.startIndex + 1] == RemoteFrameType.terminalGridSnapshot.rawValue
    }

    var isOutput: Bool {
        data.count > 1 && data[data.startIndex + 1] == RemoteFrameType.output.rawValue
    }
}

/// Bounded application-side receive queue. Control and output frames remain
/// FIFO; full-grid snapshots are replaceable state, so only the newest queued
/// grid survives. Removing the old grid and appending the new one preserves the
/// retained frames' encrypted sequence order.
struct RemoteInboundMessageQueue {
    private(set) var messages: [RemoteInboundMessage] = []
    private(set) var bufferedBytes = 0
    private(set) var supersededGridFrames = 0
    private(set) var outputRecoveryPending = false
    let maxBufferedBytes: Int

    init(maxBufferedBytes: Int = 2 * 1024 * 1024) {
        self.maxBufferedBytes = maxBufferedBytes
    }

    var isEmpty: Bool {
        messages.isEmpty
    }

    mutating func enqueue(data: Data, generation: UInt64, receivedAt: Date = Date()) {
        let isGrid = data.count > 1
            && data[data.startIndex + 1] == RemoteFrameType.terminalGridSnapshot.rawValue
        let isOutput = data.count > 1
            && data[data.startIndex + 1] == RemoteFrameType.output.rawValue
        if isGrid {
            while let index = messages.firstIndex(where: \.isGridSnapshot) {
                bufferedBytes -= messages.remove(at: index).data.count
                supersededGridFrames += 1
            }
        }

        let message = RemoteInboundMessage(
            data: data,
            generation: generation,
            receivedAt: receivedAt,
            queueDepthAtEnqueue: messages.count + 1,
            suppressOutputApplication: outputRecoveryPending && isOutput
        )
        messages.append(message)
        bufferedBytes += data.count

        // Only replaceable grid state is shed. Never discard terminal output
        // or control frames: those carry ordered user-visible/session events.
        while bufferedBytes > maxBufferedBytes,
              let gridIndex = messages.firstIndex(where: \.isGridSnapshot)
        {
            bufferedBytes -= messages.remove(at: gridIndex).data.count
            supersededGridFrames += 1
        }

        // Encrypted output must still be decrypted/admitted in sequence, but
        // once ordered bytes exceed the budget it is faster and safer to skip
        // their UI application and recover from one authoritative checkpoint.
        if bufferedBytes > maxBufferedBytes, messages.contains(where: \.isOutput) {
            outputRecoveryPending = true
            for index in messages.indices where messages[index].isOutput {
                messages[index].suppressOutputApplication = true
            }
        }
    }

    mutating func popFirst() -> RemoteInboundMessage? {
        guard !messages.isEmpty else { return nil }
        let message = messages.removeFirst()
        bufferedBytes -= message.data.count
        return message
    }

    mutating func takeSupersededGridCount() -> Int {
        defer { supersededGridFrames = 0 }
        return supersededGridFrames
    }

    mutating func takeOutputRecoverySignalIfDrained() -> Bool {
        guard messages.isEmpty, outputRecoveryPending else { return false }
        outputRecoveryPending = false
        return true
    }

    mutating func removeAll() {
        messages.removeAll(keepingCapacity: true)
        bufferedBytes = 0
        supersededGridFrames = 0
        outputRecoveryPending = false
    }
}

/// Owns the relay WebSocket: the task itself, the generation counter that
/// invalidates stale async work after a reconnect, the ordered application
/// queue, inbound rate limiting, and raw sends.
///
/// Extracted from `RemoteClient` (C6): the transport knows nothing about
/// crypto, frames, or session state — it delivers raw message data (tagged
/// with the generation it was received under) and reports receive failures.
/// Socket receives continue while the ordered application queue is draining,
/// preventing CPU/render work from stalling the network receive window.
@MainActor
final class RemoteTransport {
    /// Bumped on every close; async work captures the generation it started
    /// under and re-checks it after each suspension point.
    private(set) var generation: UInt64 = 0

    private var webSocketTask: URLSessionWebSocketTask?
    private var frameRateLimiter = RemoteFrameRateLimiter()
    private var lastThrottleLogAt: Date?
    private var inboundQueue = RemoteInboundMessageQueue()
    private var drainTask: Task<Void, Never>?

    /// Awaited serially by the application-queue drain. Queue age/depth and
    /// superseded-grid count feed streaming performance diagnostics.
    var onMessage: (@MainActor (RemoteInboundMessage, Int) async -> Void)?
    /// A receive failure for the current generation (stale-generation
    /// failures are swallowed — the socket they belonged to is gone).
    var onFailure: (@MainActor (Error) -> Void)?
    var onOutputRecoveryNeeded: (@MainActor () -> Void)?

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
        drainTask?.cancel()
        drainTask = nil
        inboundQueue.removeAll()
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
            case let .failure(error):
                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation else { return }
                    log.error("WebSocket receive failed: \(error.localizedDescription)")
                    self.onFailure?(error)
                }
            case let .success(msg):
                let data: Data
                switch msg {
                case let .data(frameData):
                    data = frameData
                case let .string(text):
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
                    self.inboundQueue.enqueue(data: data, generation: generation)
                    self.startDrainIfNeeded()
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

    private func startDrainIfNeeded() {
        guard drainTask == nil, !inboundQueue.isEmpty else { return }
        drainTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, let message = self.inboundQueue.popFirst() {
                guard message.generation == self.generation else { continue }
                let supersededGrids = self.inboundQueue.takeSupersededGridCount()
                await self.onMessage?(message, supersededGrids)
                guard message.generation == self.generation else { return }
            }
            self.drainTask = nil
            if self.inboundQueue.takeOutputRecoverySignalIfDrained() {
                self.onOutputRecoveryNeeded?()
            }
            // Actor reentrancy can enqueue a message between the final pop and
            // task teardown. Re-check so that message cannot become stranded.
            self.startDrainIfNeeded()
        }
    }

    private func noteThrottle() {
        let now = Date()
        if let last = lastThrottleLogAt, now.timeIntervalSince(last) < 5 {
            return
        }
        lastThrottleLogAt = now
        log.warning("Inbound frame rate throttled (possible relay flood)")
    }
}
