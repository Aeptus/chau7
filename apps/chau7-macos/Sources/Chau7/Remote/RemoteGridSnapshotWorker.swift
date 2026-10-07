import Foundation
import Chau7Core

/// Queue confinement protects the only retained viewport. AppKit/backend
/// objects never leave main; only immutable owned row bytes reach this worker.
final class RemoteGridSnapshotWorker: @unchecked Sendable {
    struct Result: Sendable {
        let payload: Data?
        let generation: UInt64
        let retainedBytes: Int
    }

    private let queue = DispatchQueue(label: "com.chau7.remote-grid-encode", qos: .userInitiated)
    private var cache = RemoteGridSnapshotCache()
    private var scope: String?
    private var lastReportedRetainedBytes: Int?

    func encode(
        _ update: RemoteGridUpdate,
        scope: String,
        completion: @escaping @Sendable (Result) -> Void
    ) {
        queue.async { [self] in
            if self.scope != scope {
                cache.reset()
                self.scope = scope
            }
            let payload = TerminalWorkProfiler.shared.measure(
                .remoteGridEncode,
                context: TerminalWorkContext(renderPhase: "remote", visibility: "subscriber", caller: "gridEncoder"),
                bytes: { $0?.count ?? 0 }
            ) { cache.encode(update) }
            if lastReportedRetainedBytes != cache.retainedBytes {
                lastReportedRetainedBytes = cache.retainedBytes
                PerformanceTelemetryWriter.shared.record(category: "remote_grid_cache", fields: [
                    "retained_bytes": cache.retainedBytes,
                    "budget_bytes": RemoteGridSnapshotCache.defaultMaximumBytes
                ])
            }
            completion(Result(payload: payload, generation: cache.generation, retainedBytes: cache.retainedBytes))
        }
    }

    func reset() {
        queue.async { [self] in
            cache.reset()
            scope = nil
            if lastReportedRetainedBytes != 0 {
                lastReportedRetainedBytes = 0
                PerformanceTelemetryWriter.shared.record(category: "remote_grid_cache", fields: [
                    "retained_bytes": 0,
                    "budget_bytes": RemoteGridSnapshotCache.defaultMaximumBytes
                ])
            }
        }
    }
}
