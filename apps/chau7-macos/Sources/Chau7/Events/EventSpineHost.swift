import Chau7Core
import Foundation

/// The single consumer of the event spine's envelope stream.
///
/// Exactly one pump task iterates `EventSpine.envelopes` and hands each
/// envelope, on the main actor and in seq order, to the projection closure
/// (AppModel's unified-event pipeline). Determinism comes from
/// seq-at-ingest (fixed in `EventSpine`) plus this single ordered consumer —
/// replacing the scattered `DispatchQueue.main.async` fan-out that made
/// cross-producer delivery order scheduler-dependent.
@MainActor
final class EventSpineHost {

    private var pumpTask: Task<Void, Never>?

    /// AppModel stores the host from a nonisolated init; actual pump state is
    /// only touched on the main actor via `start`/`stop`.
    nonisolated init() {}

    /// The pump's `for await` holds the spine strongly; cancel on dealloc so
    /// a discarded AppModel (tests) releases its spine instead of leaking a
    /// live pump with a dead delivery target.
    deinit {
        pumpTask?.cancel()
    }

    /// Starts the pump. Idempotent: subsequent calls are no-ops (the spine's
    /// stream supports exactly one consumer).
    func start(
        spine: EventSpine,
        deliver: @escaping @MainActor (EventEnvelope) -> Void
    ) {
        guard pumpTask == nil else { return }
        pumpTask = Task { @MainActor in
            for await envelope in spine.envelopes {
                deliver(envelope)
            }
        }
    }

    func stop() {
        pumpTask?.cancel()
        pumpTask = nil
    }
}
