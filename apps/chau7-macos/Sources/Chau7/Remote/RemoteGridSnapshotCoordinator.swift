import Foundation
import Chau7Core

/// Main owns admission, scheduling and delivery epochs; the existing worker
/// receives only owned row bytes and returns immutable encoded results.
@MainActor
final class RemoteGridSnapshotCoordinator {
    struct Context: Sendable {
        let isConnected: Bool
        let streamsTerminal: Bool
        let selectedTab: UInt32?
        let sessionID: String?
    }

    typealias Encoding = (RemoteGridUpdate, String, @escaping @Sendable (RemoteGridSnapshotWorker.Result) -> Void) -> Void
    private let target: (UInt32) -> String?
    private let capture: (UInt32, UInt64) -> RemoteGridUpdate?
    private let context: (UInt32) -> Context
    private let deliver: (UInt32, Data) -> Void
    private let encode: Encoding
    private let resetWorker: () -> Void
    private let interval: Duration
    private var flushTask: Task<Void, Never>?
    private var pendingTab: UInt32?
    private var pendingForce = false
    private(set) var encodingInFlight = false
    private var generation: UInt64 = 0
    private var scope: String?
    private var epoch: UInt64 = 0

    init(
        interval: Duration = RemoteOutputTuning.gridSnapshotInterval,
        target: @escaping (UInt32) -> String?,
        capture: @escaping (UInt32, UInt64) -> RemoteGridUpdate?,
        context: @escaping (UInt32) -> Context,
        deliver: @escaping (UInt32, Data) -> Void,
        worker: RemoteGridSnapshotWorker = RemoteGridSnapshotWorker(),
        encodeForTesting: Encoding? = nil
    ) {
        self.interval = interval
        self.target = target
        self.capture = capture
        self.context = context
        self.deliver = deliver
        self.encode = encodeForTesting ?? { worker.encode($0, scope: $1, completion: $2) }
        self.resetWorker = { worker.reset() }
    }

    func request(for tab: UInt32, force: Bool = true) {
        guard let session = target(tab) else { return }
        if encodingInFlight {
            enqueue(tab, force: force)
            return
        }
        let capturedEpoch = epoch
        let nextScope = "\(capturedEpoch)/\(session)"
        if scope != nextScope {
            scope = nextScope
            generation = 0
        }
        guard let update = capture(tab, force ? 0 : generation) else { return }
        encodingInFlight = true
        encode(update, nextScope) { [weak self] result in
            Task { @MainActor [weak self] in
                self?.complete(result, tab: tab, session: session, capturedEpoch: capturedEpoch)
            }
        }
    }

    func schedule(for tab: UInt32) {
        enqueue(tab, force: false)
        guard flushTask == nil else { return }
        flushTask = Task { @MainActor [weak self, interval] in
            try? await Task.sleep(for: interval)
            guard let self, !Task.isCancelled else { return }
            flushTask = nil
            drainPending(deferOrdinary: false)
        }
    }

    /// Keep an old encode in flight until its callback retires. This preserves
    /// the one-job bound even when reconnect/selection invalidates its result.
    func invalidate() {
        flushTask?.cancel()
        flushTask = nil
        pendingTab = nil
        pendingForce = false
        epoch &+= 1
        generation = 0
        scope = nil
        resetWorker()
    }

    private func enqueue(_ tab: UInt32, force: Bool) {
        pendingForce = pendingTab == tab ? pendingForce || force : force
        pendingTab = tab
    }

    private func complete(_ result: RemoteGridSnapshotWorker.Result, tab: UInt32, session: String, capturedEpoch: UInt64) {
        encodingInFlight = false
        let current = context(tab)
        if RemoteGridDeliveryPolicy.shouldDeliver(
            capturedEpoch: capturedEpoch, currentEpoch: epoch,
            capturedTab: tab, selectedTab: current.selectedTab,
            capturedSession: session, currentSession: current.sessionID,
            isConnected: current.isConnected, streamsTerminal: current.streamsTerminal
        ) {
            generation = result.generation
            if let payload = result.payload { deliver(tab, payload) }
        }
        drainPending(deferOrdinary: true)
    }

    private func drainPending(deferOrdinary: Bool) {
        guard let tab = pendingTab else { return }
        let force = pendingForce
        pendingTab = nil
        pendingForce = false
        guard tab == context(tab).selectedTab else { return }
        if force || !deferOrdinary { request(for: tab, force: force) } else { schedule(for: tab) }
    }
}
