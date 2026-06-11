import Foundation
import Chau7Core

/// Producer-facing surface of the notification system. The two methods
/// here cover every reason a producer reaches into `NotificationManager`:
/// recording an event for delivery (`notify(for:)`) and routing a custom
/// notification payload through the full authorization + AppleScript
/// fallback chain (`dispatchActionNotification`, used by the
/// `.showNotification` action handler).
///
/// Defined as an `AnyObject` protocol so callers that need it (most
/// notably `NotificationActionExecutor`'s environment closure) can hold
/// a weak reference and avoid a retain cycle when the publisher is also
/// the manager that owns the executor.
@MainActor
protocol NotificationPublishing: AnyObject {
    /// Record an event for delivery. Marshals to the main thread; safe
    /// to call from any thread.
    func notify(for event: AIEvent)

    /// Route a custom title/body through the manager's dispatch path
    /// (UNUserNotificationCenter when authorized, AppleScript fallback
    /// otherwise). Used by the showNotification action handler.
    @discardableResult
    func dispatchActionNotification(title: String, body: String, for event: AIEvent) -> Bool
}

/// Composition root for the notification system. Constructs the
/// `NotificationActionExecutor` and the `NotificationManager`, wires
/// each into the other (executor consults the manager as its publisher;
/// manager dispatches actions through the executor), and exposes both
/// as plain instance properties so callers stop reaching into the
/// previous `.shared` singletons.
///
/// Lifecycle:
///
/// * `AppModel.init` constructs one `NotificationServices` and stores
///   it as a strong property.
/// * `AppModel.init` also assigns `NotificationServices.current` so
///   types that can't easily reach `AppModel` (status bar, debug
///   console, settings views with deep view hierarchies) can still find
///   the composition root.
/// * Tests can construct their own `NotificationServices()` and assign
///   to `current` to isolate from the production graph.
@MainActor
final class NotificationServices {
    let manager: NotificationManager
    let executor: NotificationActionExecutor

    init() {
        let executor = NotificationActionExecutor()
        let manager = NotificationManager(executor: executor)
        // Two-step wiring breaks the circular construction: the
        // executor needs a publisher reference (the manager); the
        // manager needs an executor reference (already injected via
        // init). Setting the publisher post-construction is the
        // standard way to resolve the cycle without globals.
        executor.publisher = manager
        self.executor = executor
        self.manager = manager
    }

    /// Service-locator slot populated by `AppModel.init`. View-layer
    /// callsites that can't easily thread a `NotificationServices`
    /// reference through their construction (status bar, debug
    /// console, settings views) read through this.
    ///
    /// Production code never reads `current` before `AppModel.init`
    /// runs; tests that touch view-layer types set `current` in
    /// `setUp()`. `nonisolated(unsafe)` because the slot follows a
    /// strict "set once at app startup, read everywhere after" pattern
    /// — the write happens before any reader runs.
    nonisolated(unsafe) static var current: NotificationServices?
}

// MARK: - NotificationManager conformance

extension NotificationManager: NotificationPublishing {}

