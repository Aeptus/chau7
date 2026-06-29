import Foundation
import Chau7Core

/// What `NotificationManager` needs from "whatever knows about live
/// terminal tabs across every window" — replaces five separately-set
/// closure properties (`tabTitleProvider`, `repoNameProvider`,
/// `activeTabChecker`, `tabResolver`, `strictTabResolver`) with one
/// protocol injection.
///
/// One conformer (`TerminalControlService`) covers all five methods —
/// the closures were always routing to it anyway. The protocol exists so
/// the manager doesn't have to import the MCP / overlay machinery just
/// to ask "what's the title of this tab" and so tests can inject a
/// stub host without spinning up the full terminal stack.
///
/// Marked `AnyObject` because every realistic conformer is a class +
/// the manager holds a weak reference to avoid a retain cycle when the
/// host wires itself into the singleton.
protocol NotificationDeliveryHost: AnyObject {
    /// Display title for the tab matching `target`, if any. Used to fill
    /// the notification subtitle's "Tab: X" segment.
    func notificationTabTitle(for target: TabTarget) -> String?

    /// Repository name for the tab matching `target`, if any. Used to
    /// fill the notification subtitle's "Repo: X" segment and the
    /// notification title's repo prefix.
    func notificationRepoName(for target: TabTarget) -> String?

    /// Whether the tab matching `target` is currently the selected tab
    /// in its window. Drives the `onlyWhenTabInactive` trigger condition.
    func notificationIsActiveTab(_ target: TabTarget) -> Bool

    /// Resolve the UUID for a tab matching `target` using the full
    /// 5-tier resolution path (exact ID → session ID → brand → title →
    /// CWD fallback).
    func notificationResolveTab(_ target: TabTarget) -> UUID?

    /// Strict resolver — exact session match only, no brand / title /
    /// CWD fallback. Used for authoritative events that must never
    /// route to a wrong tab via heuristics.
    func notificationResolveTabStrictly(_ target: TabTarget) -> UUID?
}

// MARK: - TerminalControlService conformance

/// Thin shims forwarding the protocol's `notification*` selectors to
/// `TerminalControlService`'s existing tab APIs. Renamed selectors so
/// the protocol doesn't collide with `TerminalControlService.resolveTabID(for:strictSession:)`
/// (whose default argument would have shadowed a same-named protocol
/// requirement).
extension TerminalControlService: NotificationDeliveryHost {
    func notificationTabTitle(for target: TabTarget) -> String? {
        tabTitle(for: target)
    }

    func notificationRepoName(for target: TabTarget) -> String? {
        repoName(for: target)
    }

    func notificationIsActiveTab(_ target: TabTarget) -> Bool {
        isActiveTab(target)
    }

    func notificationResolveTab(_ target: TabTarget) -> UUID? {
        resolveTabID(for: target)
    }

    func notificationResolveTabStrictly(_ target: TabTarget) -> UUID? {
        resolveTabID(for: target, strictSession: true)
    }
}
