import Foundation
import Chau7Core

/// Owns the styleTab action's retry/recovery state machine — the live-tab
/// lookup, the deferred-retry scheduler, the auto-clear timer, and the
/// "redundant style re-apply" suppression. Extracted from
/// `NotificationActionExecutor` so the ~250-line styleTab path stops
/// interleaving with the other 23 action implementations and so the state
/// machine is unit-testable in isolation.
///
/// Public surface:
///
/// * `apply(event:config:)` — entry point from the executor's action
///   dispatch. Returns an `ExecutionReport` so the executor's aggregate
///   accumulator pattern still works.
/// * `cancelPendingWork(tabID:sessionID:)` — called by `NotificationManager`
///   when a fresh interactive-attention event supersedes an in-flight
///   auto-clear timer.
/// * `reset()` — full reset for `NotificationActionExecutor.resetForTesting()`.
/// * `delegate` — set by the executor's `delegate` `didSet`; never
///   accessed during construction so a missing delegate at first call
///   just records a failure note (matches the previous behavior).
///
/// State held: three keyed-by-tabID dictionaries (`lastAppliedPreset`,
/// `pendingStyleClears`, `pendingStyleRetries`) and one static retry
/// delay. All access on `@MainActor`.
@MainActor
final class StyleTabCoordinator {
    /// Tracks the last style preset applied per tab to avoid redundant re-applies.
    private var lastAppliedPreset: [UUID: String] = [:]

    /// Pending auto-clear work items per tab ID — cancelled when a new
    /// style is applied to the same tab.
    private var pendingStyleClears: [UUID: DispatchWorkItem] = [:]

    /// Pending deferred retries per event ID — scheduled when the live
    /// styleTab call comes back nil but a recoverable tab can be found
    /// via the session ID.
    private var pendingStyleRetries: [UUID: PendingStyleRetry] = [:]

    private static let styleRetryDelay: TimeInterval = 0.2

    weak var delegate: NotificationActionDelegate?

    private struct PendingStyleRetry {
        let eventID: UUID
        let tabID: UUID
        let sessionID: String?
        let workItem: DispatchWorkItem
    }

    // MARK: - Public API

    func apply(
        event: AIEvent,
        config actionConfig: NotificationActionConfig
    ) -> NotificationActionExecutor.ExecutionReport {
        let stylePreset = actionConfig.configValue("style") ?? "waiting"
        let config = actionConfig.config
        let autoClearSeconds = actionConfig.configInt("autoClearSeconds", default: 0)
        var report = NotificationActionExecutor.ExecutionReport()

        guard let tabID = event.tabID else {
            let note = "styleTab missing explicit tabID"
            Log.warn("Action styleTab: Missing explicit tabID for event \(event.id.uuidString)")
            report.recordFailure(note)
            return report
        }

        // Suppress redundant style re-applies: if the tab already has this style
        // and an auto-clear timer is running, don't re-set and restart the timer.
        // Prevents idle re-notifications from resetting the 30s clear countdown.
        if stylePreset != "clear",
           lastAppliedPreset[tabID] == stylePreset,
           pendingStyleClears[tabID] != nil {
            Log.trace("Skipping redundant style '\(stylePreset)' for tab \(tabID)")
            report.recordSuccess(.styleTab)
            return report
        }

        let resolvedTabID = resolveLiveStyleTabID(
            event: event,
            explicitTabID: tabID,
            preset: stylePreset,
            config: config
        )

        guard let resolvedTabID else {
            if scheduleDeferredStyleRetryIfNeeded(
                event: event,
                explicitTabID: tabID,
                preset: stylePreset,
                config: config,
                autoClearSeconds: autoClearSeconds
            ) {
                report.recordSuccess(.styleTab)
                report.notes.append("styleTab deferred retry scheduled for explicit tabID \(tabID.uuidString)")
                return report
            }
            let note = "styleTab failed for explicit tabID \(tabID.uuidString)"
            if delegate?.tabExists(tabID: tabID) == false {
                Log.info(
                    "Action styleTab: skipped missing explicit tabID \(tabID) for event \(event.id.uuidString)"
                )
            } else {
                Log.warn("Action styleTab: Explicit tabID not found across windows for event \(event.id.uuidString)")
            }
            report.recordFailure(note)
            return report
        }

        applyResolvedStyle(
            resolvedTabID,
            preset: stylePreset,
            autoClearSeconds: autoClearSeconds,
            event: event
        )
        report.recordSuccess(.styleTab)
        return report
    }

    func cancelPendingWork(tabID: UUID? = nil, sessionID: String? = nil) {
        let normalizedSessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let tabID {
            pendingStyleClears.removeValue(forKey: tabID)?.cancel()
            lastAppliedPreset.removeValue(forKey: tabID)
        }

        let retryIDs = pendingStyleRetries.compactMap { eventID, retry -> UUID? in
            let matchesTab = tabID.map { retry.tabID == $0 } ?? false
            let matchesSession = normalizedSessionID.map { retry.sessionID == $0 } ?? false
            return (matchesTab || matchesSession) ? eventID : nil
        }

        for eventID in retryIDs {
            pendingStyleRetries.removeValue(forKey: eventID)?.workItem.cancel()
        }
    }

    func reset() {
        pendingStyleClears.values.forEach { $0.cancel() }
        pendingStyleRetries.values.forEach { $0.workItem.cancel() }
        pendingStyleClears.removeAll()
        pendingStyleRetries.removeAll()
        lastAppliedPreset.removeAll()
    }

    // MARK: - Static pure helper (exposed for testing)

    /// Resolves which tab the auto-clear timer should target when it fires.
    /// If the original tab still exists, return it; otherwise attempt to
    /// recover via the event's session ID (handles the case where the tab
    /// was closed and re-opened with a fresh UUID for the same session).
    static func resolveAutoClearTabID(
        originalTabID: UUID,
        event: AIEvent,
        tabExists: (UUID) -> Bool,
        resolveExactTab: (TabTarget) -> UUID?
    ) -> UUID? {
        if tabExists(originalTabID) {
            return originalTabID
        }

        guard let sessionID = event.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty else {
            return nil
        }

        let exactTarget = TabTarget(
            tool: event.tool,
            directory: event.directory,
            tabID: nil,
            sessionID: sessionID
        )

        guard let recoveredTabID = resolveExactTab(exactTarget),
              tabExists(recoveredTabID) else {
            return nil
        }

        return recoveredTabID
    }

    // MARK: - Private helpers

    private func applyResolvedStyle(
        _ resolvedTabID: UUID,
        preset stylePreset: String,
        autoClearSeconds: Int,
        event: AIEvent
    ) {
        if stylePreset == "clear" {
            lastAppliedPreset.removeValue(forKey: resolvedTabID)
        } else {
            lastAppliedPreset[resolvedTabID] = stylePreset
        }

        pendingStyleClears[resolvedTabID]?.cancel()
        pendingStyleClears.removeValue(forKey: resolvedTabID)

        if autoClearSeconds > 0 {
            let workItem = DispatchWorkItem { [weak self] in
                self?.pendingStyleClears.removeValue(forKey: resolvedTabID)
                self?.lastAppliedPreset.removeValue(forKey: resolvedTabID)
                guard let self,
                      let autoClearTabID = resolveAutoClearTabID(originalTabID: resolvedTabID, event: event)
                else {
                    Log.debug(
                        "Action styleTab: skipped auto-clear for missing tab \(resolvedTabID) event=\(event.id.uuidString)"
                    )
                    return
                }
                _ = delegate?.styleTab(tabID: autoClearTabID, preset: "clear", config: [:])
            }
            pendingStyleClears[resolvedTabID] = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(autoClearSeconds), execute: workItem)
        }
    }

    private func scheduleDeferredStyleRetryIfNeeded(
        event: AIEvent,
        explicitTabID: UUID,
        preset: String,
        config: [String: String],
        autoClearSeconds: Int
    ) -> Bool {
        guard let recoveredTabID = recoverableStyleTabID(event: event, explicitTabID: explicitTabID) else {
            return false
        }

        Log.info(
            "Action styleTab: scheduling deferred retry for stale tab \(explicitTabID) recoveredTabID=\(recoveredTabID) event=\(event.id.uuidString)"
        )
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            pendingStyleRetries.removeValue(forKey: event.id)
            guard let recoveredTabID = resolveLiveStyleTabID(
                event: event,
                explicitTabID: explicitTabID,
                preset: preset,
                config: config
            ) else {
                Log.warn(
                    "Action styleTab: deferred retry failed for explicit tabID \(explicitTabID) event=\(event.id.uuidString)"
                )
                return
            }
            applyResolvedStyle(
                recoveredTabID,
                preset: preset,
                autoClearSeconds: autoClearSeconds,
                event: event
            )
            Log.info(
                "Action styleTab: deferred retry succeeded for explicit tabID \(explicitTabID) recoveredTabID=\(recoveredTabID) event=\(event.id.uuidString)"
            )
        }
        pendingStyleRetries[event.id] = PendingStyleRetry(
            eventID: event.id,
            tabID: explicitTabID,
            sessionID: event.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
            workItem: workItem
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.styleRetryDelay, execute: workItem)
        return true
    }

    private func recoverableStyleTabID(event: AIEvent, explicitTabID: UUID) -> UUID? {
        guard let sessionID = event.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty else {
            return nil
        }

        let exactTarget = TabTarget(
            tool: event.tool,
            directory: event.directory,
            tabID: nil,
            sessionID: sessionID
        )

        guard let recoveredTabID = delegate?.resolveExactTab(target: exactTarget),
              recoveredTabID != explicitTabID,
              delegate?.tabExists(tabID: recoveredTabID) == true else {
            return nil
        }

        return recoveredTabID
    }

    private func resolveAutoClearTabID(originalTabID: UUID, event: AIEvent) -> UUID? {
        let resolved = Self.resolveAutoClearTabID(
            originalTabID: originalTabID,
            event: event,
            tabExists: { [weak delegate] tabID in
                delegate?.tabExists(tabID: tabID) == true
            },
            resolveExactTab: { [weak delegate] target in
                delegate?.resolveExactTab(target: target)
            }
        )

        if let resolved, resolved != originalTabID, let sessionID = event.sessionID {
            Log.info(
                "Action styleTab: recovered auto-clear target \(originalTabID) via exact session \(sessionID) -> \(resolved)"
            )
        }
        return resolved
    }

    private func resolveLiveStyleTabID(
        event: AIEvent,
        explicitTabID: UUID,
        preset: String,
        config: [String: String]
    ) -> UUID? {
        if delegate?.tabExists(tabID: explicitTabID) != false,
           let resolved = delegate?.styleTab(tabID: explicitTabID, preset: preset, config: config) {
            return resolved
        }

        guard let sessionID = event.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty else {
            return nil
        }

        let exactTarget = TabTarget(
            tool: event.tool,
            directory: event.directory,
            tabID: nil,
            sessionID: sessionID
        )

        guard let recoveredTabID = delegate?.resolveExactTab(target: exactTarget),
              recoveredTabID != explicitTabID else {
            return nil
        }

        Log.info(
            "Action styleTab: recovered stale tabID \(explicitTabID) via exact session \(sessionID) -> \(recoveredTabID)"
        )
        return delegate?.styleTab(tabID: recoveredTabID, preset: preset, config: config)
    }
}
