import Foundation
import Chau7Core

/// Narrow app-layer dependency for components that detect events but should
/// not own or understand AppModel state.
protocol AIEventPublishing: AnyObject {
    func recordEvent(
        source: AIEventSource,
        type: String,
        tool: String,
        message: String,
        notify: Bool,
        directory: String?,
        tabID: UUID?,
        sessionID: String?,
        producer: String?,
        reliability: AIEventReliability?
    )

    /// Publish an event the producer has already fully constructed (identity
    /// resolved, timestamp set). Enters the same spine funnel as
    /// `recordEvent`; there is no delivery path that bypasses it.
    func publishPreparedEvent(_ event: AIEvent, notify: Bool)
}

extension AppModel: AIEventPublishing {
    func publishPreparedEvent(_ event: AIEvent, notify: Bool) {
        publishUnifiedEvent(event, notify: notify)
    }
}
