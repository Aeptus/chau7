import Foundation
import Chau7Core

/// Contract for one notification action implementation. Each handler
/// covers one or more `NotificationActionType` cases — most cover
/// exactly one, the time-tracking handler covers three so the trio can
/// share its `activeTimers` state.
///
/// Handlers are constructed once at registry build time and shared
/// across every action invocation (stateful handlers like FlashScreen,
/// VoiceAnnounce, and TimeTracking carry their persistent state on the
/// instance). Stateless handlers are simple structs.
///
/// Both arguments are passed in: `payload` is what's specific to the
/// firing event + config; `environment` is the long-lived collaborators
/// the executor injected (delegate, styleCoordinator, dispatch closures).
@MainActor
protocol NotificationActionHandler {
    /// The action type(s) this handler covers. The registry uses the
    /// first value as its primary key; handlers that cover multiple
    /// types (currently only TimeTracking) declare them all so the
    /// registry can route every relevant type to the shared instance.
    var supportedActionTypes: [NotificationActionType] { get }

    func execute(
        payload: ActionPayload,
        environment: ActionEnvironment
    ) -> NotificationActionExecutor.ExecutionReport
}

/// What a handler needs to know about the firing event + the specific
/// action config. Pure data + small helpers — no side effects.
/// Replaces the previous `NotificationActionExecutor.ActionContext`
/// nested struct so handlers in their own files can construct one
/// without reaching into the executor type.
struct ActionPayload {
    let event: AIEvent
    let config: NotificationActionConfig

    func configValue(_ key: String) -> String? {
        config.config[key]
    }

    func configBool(_ key: String, default defaultValue: Bool = false) -> Bool {
        config.configBool(key, default: defaultValue)
    }

    func configInt(_ key: String, default defaultValue: Int = 0) -> Int {
        config.configInt(key, default: defaultValue)
    }

    /// Replace template variables in a string. Returns `event.message`
    /// when the template is nil/empty — preserves the legacy behavior
    /// that handlers like showNotification / playSound / runScript rely
    /// on for their default "use the event's message" path.
    func interpolate(_ template: String?) -> String {
        guard let template, !template.isEmpty else {
            return event.message
        }
        return template
            .replacingOccurrences(of: "${message}", with: event.message)
            .replacingOccurrences(of: "${type}", with: event.type)
            .replacingOccurrences(of: "${tool}", with: event.tool)
            .replacingOccurrences(of: "${source}", with: event.source.rawValue)
            .replacingOccurrences(of: "${timestamp}", with: event.ts)
            .replacingOccurrences(of: "${id}", with: event.id.uuidString)
    }

    func eventJSON() -> [String: Any] {
        [
            "id": event.id.uuidString,
            "source": event.source.rawValue,
            "type": event.type,
            "tool": event.tool,
            "message": event.message,
            "timestamp": event.ts
        ]
    }

    func environmentVariables() -> [String: String] {
        [
            "CHAU7_EVENT_ID": event.id.uuidString,
            "CHAU7_SOURCE": event.source.rawValue,
            "CHAU7_TYPE": event.type,
            "CHAU7_TOOL": event.tool,
            "CHAU7_MESSAGE": event.message,
            "CHAU7_TIMESTAMP": event.ts
        ]
    }
}

/// Long-lived collaborators a handler may need. Constructed once by the
/// executor and passed verbatim into every `handler.execute(...)` call.
/// Owns nothing; just routes references. `delegate` is mutated on the
/// executor's `didSet` so handlers always see the live UI delegate.
@MainActor
final class ActionEnvironment {
    weak var delegate: NotificationActionDelegate?

    /// Owns the styleTab state machine. `StyleTabActionHandler` reads
    /// through this to apply styles; `NotificationManager` reads
    /// through it to cancel pending work on interactive-attention
    /// assertion.
    let styleCoordinator: StyleTabCoordinator

    /// Routes a `.showNotification` action's payload through the
    /// manager's full authorization + AppleScript fallback chain. The
    /// closure abstracts the manager so handlers don't reach into
    /// `NotificationManager.shared` directly (which would block Phase
    /// B's constructor-injection work).
    let dispatchActionNotification: (_ title: String, _ body: String, _ event: AIEvent) -> Bool

    init(
        styleCoordinator: StyleTabCoordinator,
        dispatchActionNotification: @escaping (_ title: String, _ body: String, _ event: AIEvent) -> Bool
    ) {
        self.styleCoordinator = styleCoordinator
        self.dispatchActionNotification = dispatchActionNotification
    }
}
