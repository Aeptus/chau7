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
}

extension AppModel: AIEventPublishing {}
