import Foundation
import AppKit
import UserNotifications
import Chau7Core

@MainActor
final class NotificationManager {
    private let isIsolatedTestMode = RuntimeIsolation.isIsolatedTestMode()

    /// Action executor injected by `NotificationServices` at
    /// construction. Used for the action-dispatch calls inside the
    /// manager that used to reach into a separate singleton.
    private let executor: NotificationActionExecutor

    /// Tracks whether UNUserNotificationCenter is available and authorized
    private var useNativeNotifications = true
    private var loggedAuthorizationStatuses: Set<UNAuthorizationStatus> = []
    private var didLogNativeError = false
    private var nativeNotificationFailureCount = 0
    private var nativeNotificationErrorCooldownUntil: Date?
    private let nativeNotificationBaseCooldown: TimeInterval = 15
    private let nativeNotificationMaxCooldown: TimeInterval = 300

    /// Source of truth for tab metadata, active-tab checks, and tab
    /// routing. One injection point replaces the five separate closure
    /// properties (tabTitleProvider, repoNameProvider, activeTabChecker,
    /// tabResolver, strictTabResolver) the manager used to expose. The
    /// app wires this once at startup via `setHost(_:)`; tests can pass
    /// a stub conformer for routing decisions.
    private weak var host: NotificationDeliveryHost?

    /// Rate limiter — prevents notification spam from burst events
    let rateLimiter = NotificationRateLimiter()
    /// Audit trail of fired (and rate-limited) notifications
    let history = NotificationHistory()

    /// Wire the host the manager will consult for tab title / repo name
    /// / active-tab / routing answers. Calling with `nil` clears the
    /// host (used by tests to isolate the manager from the live terminal
    /// stack).
    func setHost(_ host: NotificationDeliveryHost?) {
        self.host = host
    }

    // MARK: - Focus/DND State (push-based)

    private var isFocusModeActive = false

    // MARK: - Notification coalescing

    private let coalescingWindow: TimeInterval = MonitoringSchedule.defaultCoalescingWindow
    private var pendingNotifications: [String: AIEvent] = [:]
    private var pendingNotificationOrder: [String] = []
    private var pendingNotificationFlushWorkItem: DispatchWorkItem?
    /// Owns the four time-windowed delivery-policy maps
    /// (authoritative-event tracking, repeat suppression, post-close
    /// suppression, routing retry counters). The manager asks the policy
    /// for a verdict at each step and handles the side effects.
    private let deliveryPolicy = NotificationSuppressionCenter()
    private let eventEngine = AIEventNotificationEngine()

    init(executor: NotificationActionExecutor) {
        self.executor = executor
        guard !isIsolatedTestMode else {
            self.useNativeNotifications = false
            return
        }
        startFocusRefreshTimer()
    }

    func updateAuthorizationStatus(_ status: UNAuthorizationStatus) {
        NotificationAuthorizationStore.shared.apply(status: status)
        switch status {
        case .authorized, .provisional, .ephemeral:
            resetNativeNotificationState()
            useNativeNotifications = true
        case .denied:
            resetNativeNotificationState()
            useNativeNotifications = false
        case .notDetermined:
            resetNativeNotificationState()
        @unknown default:
            Log.warn("Unknown UNAuthorizationStatus (\(status.rawValue)) in updateAuthorizationStatus, treating as notDetermined")
            resetNativeNotificationState()
        }
    }

    // MARK: - Entry Point

    /// Notify for an event. Safe to call from any thread.
    nonisolated func notify(for event: AIEvent) {
        guard !RuntimeIsolation.isIsolatedTestMode() else {
            Log.info("Skipping notification in isolated test mode: type=\(event.type) tool=\(event.tool)")
            return
        }
        guard Bundle.main.bundleIdentifier != nil else {
            Log.info("Skipping notification (not running as bundle): type=\(event.type) tool=\(event.tool)")
            return
        }

        DispatchQueue.main.async { [weak self] in
            _ = self?.processUnifiedEvent(event, deliveryRequested: true)
        }
    }

    // MARK: - Drop Log Coalescing

    private var dropCounts: [String: Int] = [:]
    private var lastDropFlush = Date()
    private static let dropFlushInterval: TimeInterval = 10

    private func logCoalescedDrop(reason: String) {
        dropCounts[reason, default: 0] += 1
        let now = Date()
        guard now.timeIntervalSince(lastDropFlush) >= Self.dropFlushInterval else { return }
        for (coalescedReason, count) in dropCounts.sorted(by: { $0.key < $1.key }) {
            if count == 1 {
                Log.info("Notification ingress dropped: \(coalescedReason)")
            } else {
                Log.info("Notification ingress dropped: \(coalescedReason) (\(count)x in last \(Int(Self.dropFlushInterval))s)")
            }
        }
        dropCounts.removeAll()
        lastDropFlush = now
    }

    @discardableResult
    func processUnifiedEvent(
        _ event: AIEvent,
        deliveryRequested: Bool
    ) -> EnrichedEvent? {
        // Per-repo muting: one check silences every surface (local, tab
        // style, MCP visibility, and the push paths downstream of
        // acceptance) for events under a muted repo root.
        if RepoNotificationMuting.isMuted(
            repoPath: event.repoPath,
            directory: event.directory,
            mutedRepos: FeatureSettings.shared.notificationSettings.mutedRepos
        ) {
            Log.trace("Notification muted for repo: type=\(event.type) dir=\(event.directory ?? "nil")")
            return nil
        }

        switch eventEngine.process(event, deliveryRequested: deliveryRequested) {
        case .dropped(let drop):
            logEngineDrop(drop, deliveryRequested: deliveryRequested)
            return nil

        case .accepted(let accepted):
            logRawObservationIfNeeded(accepted.rawObservationNote, eventID: accepted.enrichedEvent.event.id)
            if deliveryRequested {
                processAcceptedEngineOutput(accepted)
            }
            return accepted.enrichedEvent
        }
    }

    private func logRawObservationIfNeeded(_ note: String?, eventID: UUID) {
        guard let note else { return }
        Log.trace("Notification engine observed raw event: \(note) id=\(eventID.uuidString)")
    }

    private func logEngineDrop(
        _ drop: AIEventNotificationEngine.Drop,
        deliveryRequested: Bool
    ) {
        logRawObservationIfNeeded(drop.rawObservationNote, eventID: drop.eventID)
        switch drop.stage {
        case .ingress:
            if deliveryRequested {
                logCoalescedDrop(reason: drop.reason)
            } else {
                Log.trace("Notification ingress dropped unified event: \(drop.reason) id=\(drop.eventID.uuidString)")
            }
        case .reconciliation:
            Log.info("Notification session reconciler dropped: \(drop.reason) id=\(drop.eventID.uuidString)")
        }
    }

    private func processAcceptedEngineOutput(_ output: AIEventNotificationEngine.Accepted) {
        let enriched = output.enrichedEvent
        let adapted = enriched.event
        let kind = enriched.kind
        Log.info(
            """
            Notification ingress accepted: id=\(adapted.id.uuidString) source=\(adapted.source.rawValue) type=\(adapted.type) semantic=\(kind.rawValue) reliability=\(adapted.reliability
                .rawValue) tabID=\(adapted.tabID?.uuidString ?? "nil") sessionID=\(adapted.sessionID ?? "nil")
            """
        )
        history.begin(
            event: adapted,
            semanticKind: kind.rawValue,
            rawType: adapted.rawType,
            notificationType: adapted.notificationType
        )
        clearStalePermissionStyleIfNeeded(event: adapted, semanticKind: kind)

        forwardTaskCompletionPushIfEnabled(enriched)

        switch output.delivery {
        case .disabled:
            return
        case .dropped(let drop):
            Log.info(
                "Notification session reconciler dropped: \(drop.reason) id=\(adapted.id.uuidString) source=\(adapted.source.rawValue) type=\(adapted.type) reliability=\(adapted.reliability.rawValue)"
            )
            history.markDropped(eventID: adapted.id, reason: drop.reason)
            return
        case .deliver(let intent):
            enqueueEvent(intent.event)
        }
    }

    /// Route accepted task-finished/failed notifications to iOS as a push
    /// (frame 0x52) when the settings toggle is on. Text comes from the
    /// shared formatter; identity from NotificationIdentity — the agent only
    /// dedups and gates on deliverability.
    private func forwardTaskCompletionPushIfEnabled(_ enriched: EnrichedEvent) {
        guard enriched.kind == .taskFinished || enriched.kind == .taskFailed else { return }
        let surfaces = NotificationRoutingPolicy.surfaces(
            kind: enriched.kind,
            settings: NotificationSurfaceSettings(
                pushTaskCompletions: FeatureSettings.shared.notificationSettings.pushTaskCompletionsToiOS
            )
        )
        guard surfaces.contains(.iosPush) else { return }
        let event = enriched.event
        let identity = NotificationIdentity(for: event)
        let payload = RemoteNotificationEventPayload(
            kind: enriched.kind.rawValue,
            identityKey: "\(enriched.kind.rawValue)|\(identity.scopedKey)",
            title: NotificationContentFormatter.title(
                for: event,
                repoName: host?.notificationRepoName(for: event.tabTarget)
            ),
            subtitle: NotificationContentFormatter.subtitle(
                for: event,
                tabTitle: host?.notificationTabTitle(for: event.tabTarget)
            ),
            body: NotificationContentFormatter.body(for: event),
            threadID: host?.notificationTabTitle(for: event.tabTarget)
        )
        Task { @MainActor in
            RemoteControlManager.shared.sendNotificationEvent(payload)
        }
    }

    /// Clears a tab's persistent permission-style highlight when the AI tool
    /// announces a state that supersedes the prompt (finished, failed, true
    /// idle, etc). Interactive attention events must not clear here: they may
    /// be dropped later as repeats/rate-limited events, and clearing before
    /// delivery would remove the only visible "needs input" marker.
    ///
    /// Why this lives in `ingestAcceptedEvent` rather than later: events get
    /// dropped/coalesced/dedup'd between ingress and the action pipeline. The
    /// stuck `bell.fill` we observed on the emdash-upstream tab on
    /// 2026-05-09 was caused exactly by this — the user answered the
    /// permission inside Claude Code's TUI, Claude emitted authoritative
    /// resolution follow-up events, and those got dropped at
    /// the `Trigger claude_code.idle disabled` step in `processEvent`.
    /// Calling the clearer at ingress runs before all those filters, so
    /// the resolution side-effect happens regardless of whether the user
    /// is configured to be notified about idle/waiting transitions.
    ///
    /// Why this is needed even though `clearPersistentNotificationStyleAcrossWindows`
    /// is already wired in three other call sites:
    /// `RuntimeControlService.respondToApproval` only fires when the user
    /// resolves through Chau7's runtime API; `session.onPermissionResolved`
    /// only fires when shell-event detection sees a resolution; both miss
    /// the common case where the user types `y` directly into the AI tool's
    /// TUI without Chau7 mediating the resolution. The AI tool's own
    /// state-change notification is the signal that closes that gap.
    private func clearStalePermissionStyleIfNeeded(
        event: AIEvent,
        semanticKind: NotificationSemanticKind
    ) {
        guard NotificationDeliverySemantics.shouldClearPersistentAttentionStyle(
            event: event,
            semanticKind: semanticKind
        ) else { return }
        guard let tabID = event.tabID else { return }
        _ = TerminalControlService.shared.clearPersistentNotificationStyleAcrossWindows(tabID: tabID)
    }

    private func enqueueEvent(_ event: AIEvent) {
        let key = MonitoringSchedule.notificationCoalescingKey(for: event)
        let isNewKey = pendingNotifications[key] == nil
        pendingNotifications[key] = event

        if isNewKey {
            pendingNotificationOrder.append(key)
        } else {
            history.markCoalesced(eventID: event.id, key: key)
        }

        if pendingNotificationFlushWorkItem != nil {
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.flushPendingNotifications()
        }
        pendingNotificationFlushWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + coalescingWindow, execute: workItem)
    }

    private func flushPendingNotifications() {
        let events = pendingNotificationOrder.compactMap { key in
            pendingNotifications.removeValue(forKey: key)
        }
        pendingNotificationOrder.removeAll(keepingCapacity: true)
        pendingNotificationFlushWorkItem = nil

        for event in events {
            processEvent(event)
        }
    }

    /// All processing on main actor — delegates decision to pure pipeline, then executes.
    private func processEvent(_ event: AIEvent) {
        deliveryPolicy.pruneExpired()

        let ns = FeatureSettings.shared.notificationSettings
        var preparedEvent: AIEvent
        var resolutionMethod: String
        // NotificationEventPreparation expects a closure surface; wrap
        // the host's tab resolver so the Core helper stays oblivious to
        // NotificationDeliveryHost (Core can't import from the app
        // layer).
        let preparationResolver: ((TabTarget) -> UUID?)? = host.map { h in
            { [weak h] target in h?.notificationResolveTab(target) }
        }
        switch NotificationEventPreparation.prepare(
            event,
            triggerState: ns.triggerState,
            tabResolver: preparationResolver
        ) {
        case .drop(let reason):
            Log.info("Notification dropped: \(reason) (type=\(event.type) tool=\(event.tool))")
            history.markDropped(eventID: event.id, reason: reason)
            return
        case .proceed(let prepared):
            preparedEvent = prepared.event
            resolutionMethod = prepared.resolutionMethod
        }

        if NotificationDeliverySemantics.requiresAuthoritativeRouting(preparedEvent),
           preparedEvent.tabID == nil,
           let resolvedTabID = host?.notificationResolveTabStrictly(preparedEvent.tabTarget) {
            preparedEvent = preparedEvent.resolvingTabID(resolvedTabID)
            resolutionMethod = "resolved_via_strict_session"
        }

        Log.info(
            """
            Notification delivery prepared: id=\(preparedEvent.id.uuidString) type=\(preparedEvent.type) tool=\(preparedEvent.tool) resolution=\(resolutionMethod) tabID=\(preparedEvent.tabID?
                .uuidString ?? "nil") sessionID=\(preparedEvent.sessionID ?? "nil")
            """
        )
        history.markPrepared(event: preparedEvent, resolutionMethod: resolutionMethod)

        deliveryPolicy.registerClosedIdentityIfNeeded(preparedEvent)
        clearResolvedInteractiveAttentionIfNeeded(for: preparedEvent)

        // Run the four delivery-policy verdicts in order. Each can either
        // pass, drop the event with a reason, or (only authoritative
        // routing) schedule a retry.
        let policySteps: [(name: String, verdict: NotificationSuppressionCenter.Verdict)] = [
            ("routing", deliveryPolicy.attemptAuthoritativeRoutingRetry(preparedEvent)),
            ("postClose", deliveryPolicy.attemptPostCloseSuppression(preparedEvent)),
            ("fallbackShadow", deliveryPolicy.attemptFallbackShadowSuppression(preparedEvent))
        ]
        for step in policySteps {
            switch step.verdict {
            case .pass:
                continue
            case .drop(let reason):
                if step.name == "routing" {
                    Log.warn("\(reason) (tool=\(preparedEvent.tool) session=\(preparedEvent.sessionID ?? "nil"))")
                } else {
                    Log.info("Notification dropped: \(reason) (type=\(preparedEvent.type) tool=\(preparedEvent.tool))")
                }
                history.markDropped(eventID: preparedEvent.id, reason: reason)
                return
            case .scheduleRetry(let delay, let attempt):
                history.markRetryScheduled(
                    eventID: preparedEvent.id,
                    attempt: attempt,
                    reason: "authoritative event missing exact tab route"
                )
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.enqueueEvent(preparedEvent)
                }
                return
            }
        }

        assertInteractiveAttentionIfNeeded(for: preparedEvent)

        switch deliveryPolicy.attemptRepeatSuppression(preparedEvent) {
        case .pass:
            break
        case .drop(let reason):
            Log.info("Notification dropped: \(reason) (type=\(preparedEvent.type) tool=\(preparedEvent.tool))")
            history.markDropped(eventID: preparedEvent.id, reason: reason)
            return
        case .scheduleRetry:
            assertionFailure("repeat suppression must not schedule retries")
        }

        deliveryPolicy.registerAuthoritativeEventIfNeeded(preparedEvent)

        let input = NotificationPipeline.Input(
            event: preparedEvent,
            triggerState: ns.triggerState,
            triggerConditions: ns.triggerConditions,
            actionBindings: ns.triggerActionBindings,
            groupConditions: ns.groupConditions,
            groupActionBindings: ns.groupActionBindings,
            isFocusModeActive: isFocusModeActive,
            isAppActive: NSApp.isActive,
            isToolTabActive: host?.notificationIsActiveTab(preparedEvent.tabTarget) ?? false
        )

        let decision = NotificationPipeline.evaluate(input)

        switch decision {
        case .drop(let reason):
            Log.info("Notification dropped: \(reason) (type=\(preparedEvent.type) tool=\(preparedEvent.tool))")
            history.markDropped(eventID: preparedEvent.id, reason: reason)
            deliveryPolicy.forgetRetryCount(preparedEvent.id)

        case .fireDefault(let triggerId):
            guard let keys = consumeRateLimitOrDropEvent(triggerId: triggerId, event: preparedEvent) else {
                return
            }
            let baseRateLimitKey = keys.base
            let didDispatchBanner = showDefaultNotification(for: preparedEvent)
            // Safe to call without re-checking isToolTabActive: processEvent runs
            // entirely on @MainActor, so no tab switch can interleave between the
            // pipeline's active-tab check and this call. The pipeline already
            // dropped events for active tabs before reaching .fireDefault.
            let didStyleTab = applyDefaultTabStyle(for: preparedEvent)
            var actions = ["showNotification"]
            if didStyleTab { actions.append("styleTab") }
            Log.info(
                "Notification delivery executed default path: id=\(preparedEvent.id.uuidString) trigger=\(baseRateLimitKey) banner=\(didDispatchBanner) styled=\(didStyleTab)"
            )
            history.markActionsExecuted(
                eventID: preparedEvent.id,
                triggerId: baseRateLimitKey,
                actionsExecuted: actions,
                didDispatchBanner: didDispatchBanner,
                didStyleTab: didStyleTab
            )
            history.markCompleted(eventID: preparedEvent.id)
            deliveryPolicy.registerRepeatSuppressionIfNeeded(preparedEvent)
            deliveryPolicy.forgetRetryCount(preparedEvent.id)

        case .fireStyleOnly(let triggerId, let actions):
            guard let keys = consumeRateLimitOrDropEvent(triggerId: triggerId, event: preparedEvent) else {
                return
            }
            let baseRateLimitKey = keys.base
            guard preparedEvent.tabID != nil else {
                let reason = "Style-only notification delivery requires explicit tabID"
                Log.warn("\(reason) id=\(preparedEvent.id.uuidString) type=\(preparedEvent.type) tool=\(preparedEvent.tool)")
                history.markDropped(eventID: preparedEvent.id, triggerId: baseRateLimitKey, reason: reason)
                deliveryPolicy.forgetRetryCount(preparedEvent.id)
                return
            }
            let report = executor.execute(actions: actions, for: preparedEvent)
            let actionNames = report.successfulActions
            Log.info(
                "Notification delivery executed style-only actions: id=\(preparedEvent.id.uuidString) trigger=\(baseRateLimitKey) actions=\(actionNames.joined(separator: ", ")) notes=\(report.notes.joined(separator: " | "))"
            )
            for note in report.notes {
                history.appendNote(eventID: preparedEvent.id, note: note)
            }
            history.markActionsExecuted(
                eventID: preparedEvent.id,
                triggerId: baseRateLimitKey,
                actionsExecuted: actionNames,
                didDispatchBanner: report.didDispatchBanner,
                didStyleTab: report.didStyleTab
            )
            history.markCompleted(eventID: preparedEvent.id)
            deliveryPolicy.registerRepeatSuppressionIfNeeded(preparedEvent)
            deliveryPolicy.forgetRetryCount(preparedEvent.id)

        case .fireActions(let triggerId, let actions):
            let rateLimitKey = MonitoringSchedule.notificationRateLimitKey(triggerID: triggerId, event: preparedEvent)
            guard rateLimiter.checkAndConsume(triggerId: rateLimitKey) else {
                Log.info("Rate limited: \(triggerId) for tool=\(preparedEvent.tool)")
                history.markRateLimited(eventID: preparedEvent.id, triggerId: triggerId)
                deliveryPolicy.forgetRetryCount(preparedEvent.id)
                return
            }
            let partition = NotificationActionRequirements.partitionByResolvedTabRequirement(actions)
            var aggregateReport = NotificationActionExecutor.ExecutionReport()
            if !partition.nonTabScoped.isEmpty {
                aggregateReport.append(
                    executor.execute(actions: partition.nonTabScoped, for: preparedEvent)
                )
            }

            if !partition.tabScoped.isEmpty {
                guard preparedEvent.tabID != nil else {
                    let skipped = partition.tabScoped
                        .filter(\.enabled)
                        .map(\.actionType.rawValue)
                    let reason = "Skipped tab-scoped notification actions without explicit tabID: \(skipped.joined(separator: ", "))"
                    Log.warn("\(reason) id=\(preparedEvent.id.uuidString) type=\(preparedEvent.type) tool=\(preparedEvent.tool)")
                    history.appendNote(eventID: preparedEvent.id, note: reason)
                    history.markActionsExecuted(
                        eventID: preparedEvent.id,
                        triggerId: triggerId,
                        actionsExecuted: aggregateReport.successfulActions,
                        didDispatchBanner: aggregateReport.didDispatchBanner,
                        didStyleTab: false
                    )
                    history.markCompleted(eventID: preparedEvent.id)
                    deliveryPolicy.forgetRetryCount(preparedEvent.id)
                    return
                }
                aggregateReport.append(
                    executor.execute(actions: partition.tabScoped, for: preparedEvent)
                )
            }

            if let supplementalStyleAction = NotificationStylePlanner.supplementalStyleAction(
                for: preparedEvent,
                from: actions
            ) {
                if preparedEvent.tabID != nil {
                    aggregateReport.append(
                        executor.execute(actions: [supplementalStyleAction], for: preparedEvent)
                    )
                } else {
                    let reason = "Skipped supplemental style action without explicit tabID"
                    Log.warn("\(reason) id=\(preparedEvent.id.uuidString) type=\(preparedEvent.type) tool=\(preparedEvent.tool)")
                    history.appendNote(eventID: preparedEvent.id, note: reason)
                }
            }
            for note in aggregateReport.notes {
                history.appendNote(eventID: preparedEvent.id, note: note)
            }
            Log.info(
                "Notification delivery executed configured actions: id=\(preparedEvent.id.uuidString) trigger=\(triggerId) actions=\(aggregateReport.successfulActions.joined(separator: ", ")) notes=\(aggregateReport.notes.joined(separator: " | "))"
            )
            history.markActionsExecuted(
                eventID: preparedEvent.id,
                triggerId: triggerId,
                actionsExecuted: aggregateReport.successfulActions,
                didDispatchBanner: aggregateReport.didDispatchBanner,
                didStyleTab: aggregateReport.didStyleTab
            )
            history.markCompleted(eventID: preparedEvent.id)
            deliveryPolicy.registerRepeatSuppressionIfNeeded(preparedEvent)
            deliveryPolicy.forgetRetryCount(preparedEvent.id)
        }
    }

    /// Resolve the rate-limit key pair for a delivery decision and consume
    /// one slot. Returns the (rate-limit, base) key pair on pass; on rate
    /// limit, logs the suppression, marks the event as rate-limited, drops
    /// the routing-retry counter, and returns nil — caller should `return`.
    /// Both `.fireDefault` and `.fireStyleOnly` branches share this preamble.
    private func consumeRateLimitOrDropEvent(
        triggerId: String?, event: AIEvent
    ) -> (rateLimit: String, base: String)? {
        let baseRateLimitKey = triggerId ?? "unmatched.\(event.source.rawValue).\(event.tool.lowercased())"
        let rateLimitKey = MonitoringSchedule.notificationRateLimitKey(triggerID: baseRateLimitKey, event: event)
        guard rateLimiter.checkAndConsume(triggerId: rateLimitKey) else {
            Log.info("Rate limited: \(rateLimitKey) for tool=\(event.tool)")
            history.markRateLimited(eventID: event.id, triggerId: baseRateLimitKey)
            deliveryPolicy.forgetRetryCount(event.id)
            return nil
        }
        return (rateLimitKey, baseRateLimitKey)
    }

    private func clearResolvedInteractiveAttentionIfNeeded(for event: AIEvent) {
        let semanticKind = NotificationSemanticMapping.kind(
            rawType: event.rawType,
            notificationType: event.notificationType,
            canonicalType: event.type
        )
        guard NotificationDeliverySemantics.shouldClearPersistentAttentionStyle(
            event: event,
            semanticKind: semanticKind
        ) else { return }
        guard let tabID = event.tabID,
              let resolvedStatus = resolvedCommandStatus(for: semanticKind) else {
            return
        }

        _ = TerminalControlService.shared.clearAttentionStateAcrossWindows(
            tabID: tabID,
            sessionID: event.sessionID,
            resolvedStatus: resolvedStatus,
            reason: "notification:\(event.type):resolved"
        )
    }

    private func resolvedCommandStatus(for semanticKind: NotificationSemanticKind) -> CommandStatus? {
        switch semanticKind {
        case .idle:
            return .idle
        case .taskFinished, .taskFailed, .authenticationSucceeded:
            return .done
        case .permissionRequired, .waitingForInput, .attentionRequired, .informational, .unknown:
            return nil
        }
    }

    /// Applies a default tab style for attention-worthy events when no explicit
    /// `.styleTab` action is configured. This ensures tab visual feedback works
    /// out-of-the-box without requiring user configuration.
    ///
    /// Routes through `NotificationActionExecutor` (not the delegate directly)
    /// so the executor's auto-clear timer management kicks in — the style
    /// automatically clears after 30 seconds.
    ///
    /// Returns `true` if a style action was dispatched (for audit trail).
    @discardableResult
    private func applyDefaultTabStyle(for event: AIEvent) -> Bool {
        guard let action = NotificationStylePlanner.defaultStyleAction(for: event) else { return false }
        guard event.tabID != nil else {
            let reason = "Skipped default tab style without explicit tabID"
            Log.warn("\(reason) id=\(event.id.uuidString) type=\(event.type) tool=\(event.tool)")
            history.appendNote(eventID: event.id, note: reason)
            return false
        }
        let report = executor.execute(actions: [action], for: event)
        for note in report.notes {
            history.appendNote(eventID: event.id, note: note)
        }
        return report.didStyleTab
    }

    private func assertInteractiveAttentionIfNeeded(for event: AIEvent) {
        let semanticKind = NotificationSemanticMapping.kind(
            rawType: event.rawType,
            notificationType: event.notificationType,
            canonicalType: event.type
        )
        let attentionKind = TabAttentionKind.fromNotificationSemantic(semanticKind)
        guard attentionKind.isInteractive else { return }
        guard let tabID = event.tabID else {
            let reason = "Skipped interactive tab attention without explicit tabID"
            Log.warn("\(reason) id=\(event.id.uuidString) type=\(event.type) tool=\(event.tool)")
            history.appendNote(eventID: event.id, note: reason)
            return
        }

        executor.cancelPendingStyleWork(
            tabID: tabID,
            sessionID: event.sessionID
        )
        _ = TerminalControlService.shared.assertAttentionStyleAcrossWindows(
            tabID: tabID,
            kind: attentionKind,
            reason: "notification:\(event.type)",
            sessionID: event.sessionID
        )
    }

    // MARK: - Notification Dispatch

    /// Used by the executor's .showNotification action — routes through the full
    /// authorization check + AppleScript fallback chain so custom-action notifications
    /// get the same reliability as default notifications.
    @discardableResult
    func dispatchActionNotification(title: String, body: String, for event: AIEvent) -> Bool {
        dispatchNotification(title: title, subtitle: notificationSubtitle(for: event), body: body, for: event)
    }

    @discardableResult
    private func showDefaultNotification(for event: AIEvent) -> Bool {
        let tabTitle = host?.notificationTabTitle(for: event.tabTarget)
        let repoName = host?.notificationRepoName(for: event.tabTarget)
        let title = event.notificationTitle(toolOverride: nil)
        let subtitle = event.notificationSubtitle(tabTitle: tabTitle, repoName: repoName)
        return dispatchNotification(title: title, subtitle: subtitle, body: event.notificationBody, for: event)
    }

    @discardableResult
    private func dispatchNotification(title: String, subtitle: String = "", body: String, for event: AIEvent) -> Bool {
        guard !isIsolatedTestMode else {
            Log.info("Skipping notification dispatch in isolated test mode: \(title)")
            return false
        }
        if shouldUseNativeNotifications() {
            tryNativeNotification(title: title, subtitle: subtitle, body: body, for: event)
            return true
        } else {
            sendAppleScriptNotification(title: title, subtitle: subtitle, body: body)
            return true
        }
    }

    private func tryNativeNotification(title: String, subtitle: String, body: String, for event: AIEvent) {
        guard shouldUseNativeNotifications() else {
            sendAppleScriptNotification(title: title, subtitle: subtitle, body: body)
            return
        }

        let store = NotificationAuthorizationStore.shared
        guard store.hasResolvedAuthorization else {
            store.refresh { [weak self] settings in
                self?.handleAuthorizationResult(settings.authorizationStatus, title: title, subtitle: subtitle, body: body, for: event)
            }
            return
        }

        handleAuthorizationResult(store.authorizationStatus, title: title, subtitle: subtitle, body: body, for: event)
    }

    private func handleAuthorizationResult(_ status: UNAuthorizationStatus, title: String, subtitle: String, body: String, for event: AIEvent) {
        switch status {
        case .authorized, .provisional, .ephemeral:
            resetNativeNotificationState()
            scheduleNativeNotification(title: title, subtitle: subtitle, body: body, for: event)
        case .denied:
            logAuthorizationOnce(status: .denied, message: "Native notifications denied, using AppleScript fallback")
            useNativeNotifications = false
            sendAppleScriptNotification(title: title, subtitle: subtitle, body: body)
        case .notDetermined:
            logAuthorizationOnce(status: .notDetermined, message: "Notification permission not determined, using AppleScript fallback")
            sendAppleScriptNotification(title: title, subtitle: subtitle, body: body)
        @unknown default:
            Log.warn("Unknown notification authorization status, trying AppleScript")
            sendAppleScriptNotification(title: title, subtitle: subtitle, body: body)
        }
    }

    private func scheduleNativeNotification(title: String, subtitle: String, body: String, for event: AIEvent) {
        Log.info("Scheduling notification: type=\(event.type) tool=\(event.tool)")

        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        let center = UNUserNotificationCenter.current()
        center.add(request) { [weak self] error in
            guard let error else {
                Log.info("Native notification scheduled successfully.")
                return
            }
            DispatchQueue.main.async {
                self?.handleNativeNotificationError(error, title: title, subtitle: subtitle, body: body)
            }
        }
    }

    private func handleNativeNotificationError(_ error: Error, title: String, subtitle: String, body: String) {
        nativeNotificationFailureCount += 1
        nativeNotificationErrorCooldownUntil = Date().addingTimeInterval(nextNativeCooldown())
        let cooldown = Int(nativeNotificationErrorCooldownUntil!.timeIntervalSinceNow.rounded(.up))
        if !didLogNativeError {
            Log.error("Native notification error: \(error.localizedDescription)")
            didLogNativeError = true
        } else {
            Log.warn("Native notification error: \(error.localizedDescription) (failure #\(nativeNotificationFailureCount), cooldown=\(cooldown)s)")
        }
        Log.warn("Temporarily disabling native notifications for \(cooldown)s, falling back to AppleScript.")
        sendAppleScriptNotification(title: title, subtitle: subtitle, body: body)
    }

    private func shouldUseNativeNotifications() -> Bool {
        if !useNativeNotifications {
            return false
        }

        guard let until = nativeNotificationErrorCooldownUntil else { return true }

        if until <= Date() {
            nativeNotificationErrorCooldownUntil = nil
            didLogNativeError = false
            return true
        }
        return false
    }

    private func nextNativeCooldown() -> TimeInterval {
        let failureExponent = min(max(0, nativeNotificationFailureCount), 5)
        let backoff = nativeNotificationBaseCooldown * pow(2.0, Double(failureExponent))
        return min(backoff, nativeNotificationMaxCooldown)
    }

    private func resetNativeNotificationState() {
        nativeNotificationFailureCount = 0
        nativeNotificationErrorCooldownUntil = nil
        didLogNativeError = false
    }

    private func logAuthorizationOnce(status: UNAuthorizationStatus, message: String) {
        guard !loggedAuthorizationStatuses.contains(status) else { return }
        loggedAuthorizationStatuses.insert(status)
        Log.info(message)
    }

    private func notificationSubtitle(for event: AIEvent) -> String {
        event.notificationSubtitle(
            tabTitle: host?.notificationTabTitle(for: event.tabTarget),
            repoName: host?.notificationRepoName(for: event.tabTarget)
        )
    }

    /// Send notification via AppleScript (works without code signing)
    private func sendAppleScriptNotification(title: String, subtitle: String = "", body: String) {
        let escapedTitle = title.appleScriptQuoted
        let escapedBody = body.appleScriptQuoted
        let escapedSubtitle = subtitle.appleScriptQuoted

        let script: String
        if escapedSubtitle.isEmpty {
            script = """
            display notification "\(escapedBody)" with title "\(escapedTitle)" sound name "default"
            """
        } else {
            script = """
            display notification "\(escapedBody)" with title "\(escapedTitle)" subtitle "\(escapedSubtitle)" sound name "default"
            """
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            if let appleScript = NSAppleScript(source: script) {
                appleScript.executeAndReturnError(&error)
                if let error = error {
                    Log.error("AppleScript notification error: \(error)")
                } else {
                    Log.info("AppleScript notification sent: \(title)")
                }
            } else {
                Log.error("Failed to create AppleScript for notification")
            }
        }
    }

    // MARK: - Focus/DND Detection (event-driven via NSWorkspace + distributed notifications)

    private var focusObservers: [NSObjectProtocol] = []

    private func startFocusRefreshTimer() {
        // Event-driven focus detection — zero polling.
        // NSWorkspace notifications fire on app activation changes.
        // Distributed notifications fire on screen lock/unlock.
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()

        // Use queue: nil + explicit MainActor dispatch to satisfy actor isolation
        focusObservers.append(
            workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { [weak self] _ in
                DispatchQueue.main.async { self?.refreshFocusState() }
            }
        )
        focusObservers.append(
            workspace.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: nil) { [weak self] _ in
                DispatchQueue.main.async { self?.refreshFocusState() }
            }
        )
        focusObservers.append(
            distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: nil) { [weak self] _ in
                DispatchQueue.main.async { self?.refreshFocusState() }
            }
        )
        focusObservers.append(
            distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: nil) { [weak self] _ in
                DispatchQueue.main.async { self?.refreshFocusState() }
            }
        )
        // Focus/DND preference changes (covers scheduled Focus mode activation/deactivation)
        focusObservers.append(
            distributed.addObserver(forName: .init("com.apple.notificationcenterui.dndprefs_changed"), object: nil, queue: nil) { [weak self] _ in
                DispatchQueue.main.async { self?.refreshFocusState() }
            }
        )

        // Initial state check
        refreshFocusState()
    }

    private func refreshFocusState() {
        guard !isIsolatedTestMode else {
            isFocusModeActive = false
            return
        }
        let screenLocked = isScreenLocked()

        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isFocusModeActive = (settings.notificationCenterSetting == .disabled) || screenLocked
                self.updateAuthorizationStatus(settings.authorizationStatus)
            }
        }
    }

    /// Check if the screen is locked via CGSessionCopyCurrentDictionary.
    /// Returns false (conservative) when the API is unavailable.
    private func isScreenLocked() -> Bool {
        guard let sessionInfo = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            Log.trace("CGSessionCopyCurrentDictionary returned nil (sandboxed or API unavailable)")
            return false
        }
        return sessionInfo["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
