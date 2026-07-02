import Foundation

/// Stateful reconciliation layer for AI session notification events.
///
/// Provider hooks, terminal OSC notifications, history fallbacks, and terminal
/// text heuristics can all describe the same underlying session transition.
/// This reconciler consumes explicit `AIObservation` values and emits at most
/// one user-facing notification per deterministic session state transition,
/// while still allowing later authoritative terminal turn completions from
/// long-lived provider sessions.
public final class AISessionEventReconciler {
    public enum Decision: Equatable, Sendable {
        case emit(NotificationIngress.AcceptedEvent)
        case drop(reason: String)
    }

    private struct SessionRecord {
        var aliases: Set<AIObservationIdentityAlias>
        var providerKey: String
        var state: AIObservationState
        var strength: Int
        var updatedAt: Date
    }

    private struct TransitionDecision {
        let emit: Bool
        let updatesState: Bool
        let reason: String
    }

    private var recordsByKey: [String: SessionRecord] = [:]
    private var primaryKeyByAlias: [String: String] = [:]
    private let strongerReplacementWindow: TimeInterval
    private let terminalRepeatWindow: TimeInterval
    private let retentionSeconds: TimeInterval

    public init(
        strongerReplacementWindow: TimeInterval = MonitoringSchedule.defaultCoalescingWindow,
        terminalRepeatWindow: TimeInterval = NotificationTimings.terminalRepeatWindow,
        retentionSeconds: TimeInterval = 30 * 60
    ) {
        self.strongerReplacementWindow = strongerReplacementWindow
        self.terminalRepeatWindow = terminalRepeatWindow
        self.retentionSeconds = retentionSeconds
    }

    public func reset() {
        recordsByKey.removeAll()
        primaryKeyByAlias.removeAll()
    }

    /// Observes non-notifiable raw lifecycle events, mostly to reopen a
    /// session after a terminal state when the next user turn starts.
    @discardableResult
    public func observeRawEvent(_ event: AIEvent, now: Date = Date()) -> String? {
        guard let observation = AIObservation.rawLifecycleObservation(from: event, now: now),
              let state = observation.state else {
            return nil
        }
        prune(now: now)
        let key = mergeAndPrimaryKey(for: observation)
        var record = recordsByKey[key] ?? SessionRecord(
            aliases: Set(observation.aliases),
            providerKey: observation.providerKey,
            state: .unknown,
            strength: 0,
            updatedAt: now
        )

        record.aliases.formUnion(observation.aliases)
        record.providerKey = observation.providerKey
        record.state = state
        record.strength = observation.strength
        record.updatedAt = now
        store(record, primaryKey: key)
        return "observed raw \(event.normalizedType) as \(state.rawValue)"
    }

    public func reconcile(
        _ accepted: NotificationIngress.AcceptedEvent,
        now: Date = Date()
    ) -> Decision {
        guard let observation = AIObservation.notificationObservation(from: accepted, now: now),
              observation.state != nil else {
            return .emit(accepted)
        }
        prune(now: now)
        let key = mergeAndPrimaryKey(for: observation)
        var record = recordsByKey[key] ?? SessionRecord(
            aliases: Set(observation.aliases),
            providerKey: observation.providerKey,
            state: .unknown,
            strength: 0,
            updatedAt: now
        )

        let transition = shouldEmit(observation: observation, previous: record)
        record.aliases.formUnion(observation.aliases)
        record.providerKey = observation.providerKey

        if transition.updatesState, let state = observation.state {
            record.state = state
            record.strength = observation.strength
            record.updatedAt = now
        }

        store(record, primaryKey: key)

        if transition.emit {
            return .emit(accepted)
        }
        return .drop(reason: transition.reason)
    }

    private func shouldEmit(
        observation: AIObservation,
        previous: SessionRecord
    ) -> TransitionDecision {
        guard let state = observation.state else {
            return .init(emit: true, updatesState: false, reason: "stateless observation")
        }

        if previous.state == .unknown {
            return .init(emit: true, updatesState: true, reason: "first session observation")
        }

        if previous.state.isTerminal {
            // An authoritative interactive-attention signal means the session is
            // active again: a session cannot be finished AND blocking on the user.
            // Treat it as a reopen so the next turn's prompt is never suppressed,
            // without depending on the provider emitting raw lifecycle
            // (tool_start/session_start) reopen events. Fallback/heuristic
            // attention is intentionally excluded so lagging terminal-text
            // signals stay suppressed after completion.
            if state.isInteractiveAttention, observation.reliability == .authoritative {
                return .init(
                    emit: true,
                    updatesState: true,
                    reason: "Reopened terminal session for authoritative \(state.rawValue)"
                )
            }

            if state.isTerminal {
                if state == previous.state {
                    return sameStateDecision(
                        state: state,
                        observation: observation,
                        previous: previous,
                        duplicateReason: "Duplicate terminal session state \(state.rawValue)"
                    )
                }
                if observation.strength > previous.strength {
                    return .init(emit: true, updatesState: true, reason: "stronger terminal session state")
                }
                return .init(
                    emit: false,
                    updatesState: false,
                    reason: "Stale weaker terminal session state after \(previous.state.rawValue)"
                )
            }

            return .init(
                emit: false,
                updatesState: false,
                reason: "Stale post-terminal \(state.rawValue) after \(previous.state.rawValue)"
            )
        }

        if state == previous.state {
            return sameStateDecision(
                state: state,
                observation: observation,
                previous: previous,
                duplicateReason: "Duplicate session state \(state.rawValue)"
            )
        }

        if previous.state.isInteractiveAttention,
           state.isInteractiveAttention,
           state.interactiveSpecificity <= previous.state.interactiveSpecificity,
           observation.strength <= previous.strength {
            return .init(
                emit: false,
                updatesState: false,
                reason: "Weaker duplicate interactive session state \(state.rawValue)"
            )
        }

        if state == .idle,
           previous.state.isInteractiveAttention,
           observation.reliability != .authoritative {
            return .init(
                emit: false,
                updatesState: false,
                reason: "Ignored fallback idle while session still needs attention"
            )
        }

        return .init(emit: true, updatesState: true, reason: "session state transition")
    }

    private func sameStateDecision(
        state: AIObservationState,
        observation: AIObservation,
        previous: SessionRecord,
        duplicateReason: String
    ) -> TransitionDecision {
        if observation.strength == previous.strength,
           shouldEmitRepeatedTerminalState(state: state, observation: observation, previous: previous) {
            return .init(
                emit: true,
                updatesState: true,
                reason: "repeated terminal session state \(state.rawValue)"
            )
        }

        guard observation.strength > previous.strength else {
            return .init(emit: false, updatesState: false, reason: duplicateReason)
        }

        if observation.timestamp.timeIntervalSince(previous.updatedAt) <= strongerReplacementWindow {
            return .init(emit: true, updatesState: true, reason: "stronger \(state.rawValue) replacement")
        }

        return .init(
            emit: false,
            updatesState: true,
            reason: "Updated stronger duplicate session state \(state.rawValue) without re-notifying"
        )
    }

    private func shouldEmitRepeatedTerminalState(
        state: AIObservationState,
        observation: AIObservation,
        previous: SessionRecord
    ) -> Bool {
        guard state.isTerminal else { return false }
        guard observation.reliability == .authoritative else { return false }
        guard observation.sourceClass == .providerHook || observation.sourceClass == .runtime else {
            return false
        }
        return observation.timestamp.timeIntervalSince(previous.updatedAt) > terminalRepeatWindow
    }

    private func mergeAndPrimaryKey(for observation: AIObservation) -> String {
        let linkedKeys = observation.aliases
            .compactMap { primaryKeyByAlias[$0.key] }
            .reduce(into: [String]()) { keys, key in
                if !keys.contains(key) {
                    keys.append(key)
                }
            }
            .sorted()

        guard !linkedKeys.isEmpty else {
            return observation.primaryIdentityKey
        }

        var mergedAliases = Set(observation.aliases)
        var linkedRecords: [(key: String, record: SessionRecord)] = []
        for key in linkedKeys {
            guard let record = recordsByKey[key] else { continue }
            linkedRecords.append((key, record))
            mergedAliases.formUnion(record.aliases)
        }

        let primaryKey = AIObservation.preferredPrimaryKey(
            aliases: mergedAliases,
            providerKey: observation.providerKey
        )

        if !linkedRecords.isEmpty {
            let mergedRecord = mergedRecord(
                from: linkedRecords.map(\.record),
                aliases: mergedAliases,
                providerKey: observation.providerKey
            )
            for key in linkedRecords.map(\.key) where key != primaryKey {
                recordsByKey.removeValue(forKey: key)
            }
            recordsByKey[primaryKey] = mergedRecord
            for alias in mergedAliases {
                primaryKeyByAlias[alias.key] = primaryKey
            }
        }

        return primaryKey
    }

    private func mergedRecord(
        from records: [SessionRecord],
        aliases: Set<AIObservationIdentityAlias>,
        providerKey: String
    ) -> SessionRecord {
        let selected = records.max { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt < rhs.updatedAt
            }
            if lhs.strength != rhs.strength {
                return lhs.strength < rhs.strength
            }
            return lhs.state.rawValue > rhs.state.rawValue
        }

        return SessionRecord(
            aliases: aliases,
            providerKey: providerKey,
            state: selected?.state ?? .unknown,
            strength: selected?.strength ?? 0,
            updatedAt: selected?.updatedAt ?? .distantPast
        )
    }

    private func store(_ record: SessionRecord, primaryKey: String) {
        recordsByKey[primaryKey] = record
        for alias in record.aliases {
            primaryKeyByAlias[alias.key] = primaryKey
        }
    }

    private func prune(now: Date) {
        let staleKeys = recordsByKey.compactMap { key, record -> String? in
            now.timeIntervalSince(record.updatedAt) > retentionSeconds ? key : nil
        }
        guard !staleKeys.isEmpty else { return }
        for key in staleKeys {
            guard let record = recordsByKey.removeValue(forKey: key) else { continue }
            for alias in record.aliases where primaryKeyByAlias[alias.key] == key {
                primaryKeyByAlias.removeValue(forKey: alias.key)
            }
        }
    }
}
