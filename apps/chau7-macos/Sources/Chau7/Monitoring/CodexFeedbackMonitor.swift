import Foundation
import Chau7Core

/// Watches one active Codex rollout for structured `request_user_input`
/// lifecycle records. File discovery and terminal state mutation stay outside
/// this type so the monitor has one responsibility and can be tested with a
/// temporary JSONL file.
final class CodexFeedbackMonitor {
    typealias PromptHandler = (CodexFeedbackPrompt) -> Void
    typealias ResolutionHandler = (_ callID: String, _ hasOtherPendingPrompt: Bool) -> Void

    struct HealthSnapshot: Equatable {
        enum Phase: String {
            case stopped
            case watching
        }

        let phase: Phase
        let rolloutName: String
        let linesObserved: Int
        let structuredRecordsObserved: Int
        let pendingPromptCount: Int
        let lastStructuredRecordAt: Date?

        var summary: String {
            "\(phase.rawValue) rollout=\(rolloutName) lines=\(linesObserved) "
                + "structured=\(structuredRecordsObserved) pending=\(pendingPromptCount)"
        }
    }

    private enum CallState {
        case pending(CodexFeedbackPrompt)
        case announced(CodexFeedbackPrompt)
        case completed
    }

    private let fileURL: URL
    private let debounceSeconds: TimeInterval
    private let catchUpLineLimit: Int
    private let callbackQueue: DispatchQueue
    private let onPrompt: PromptHandler
    private let onResolution: ResolutionHandler
    private let stateQueue: DispatchQueue

    private var tailer: FileTailer<String>?
    private var generation: UInt64 = 0
    private var isRunning = false
    private var statesByCallID: [String: CallState] = [:]
    private var callOrder: [String] = []
    private var pendingAnnouncements: [String: DispatchWorkItem] = [:]
    private var phase: HealthSnapshot.Phase = .stopped
    private var linesObserved = 0
    private var structuredRecordsObserved = 0
    private var lastStructuredRecordAt: Date?

    init(
        fileURL: URL,
        debounceSeconds: TimeInterval = 0.25,
        catchUpLineLimit: Int = 2_000,
        callbackQueue: DispatchQueue = .main,
        onPrompt: @escaping PromptHandler,
        onResolution: @escaping ResolutionHandler
    ) {
        self.fileURL = fileURL
        self.debounceSeconds = max(0, debounceSeconds)
        self.catchUpLineLimit = max(0, catchUpLineLimit)
        self.callbackQueue = callbackQueue
        self.onPrompt = onPrompt
        self.onResolution = onResolution
        self.stateQueue = DispatchQueue(
            label: "com.chau7.codex-feedback.\(UUID().uuidString)",
            qos: .utility
        )
    }

    /// Starts at EOF, then reconstructs unresolved calls from a bounded tail.
    /// Starting the live tail first prevents a write in the catch-up window
    /// from being skipped; call-id state makes overlap between both reads safe.
    func start() {
        let activeGeneration = stateQueue.sync { () -> UInt64 in
            guard !isRunning else { return generation }
            generation &+= 1
            isRunning = true
            statesByCallID.removeAll(keepingCapacity: true)
            callOrder.removeAll(keepingCapacity: true)
            pendingAnnouncements.values.forEach { $0.cancel() }
            pendingAnnouncements.removeAll(keepingCapacity: true)
            phase = .watching
            linesObserved = 0
            structuredRecordsObserved = 0
            lastStructuredRecordAt = nil
            return generation
        }

        guard tailer == nil else { return }
        let tailer = FileTailer<String>(
            fileURL: fileURL,
            pollInterval: .milliseconds(200),
            createIfMissing: false,
            queueLabel: "com.chau7.codex-feedback-tailer.\(UUID().uuidString)",
            parser: { $0 },
            onItem: { [weak self] line in
                self?.enqueue(line: line, generation: activeGeneration)
            }
        )
        self.tailer = tailer
        tailer.start()

        stateQueue.async { [weak self] in
            guard let self, isCurrent(activeGeneration) else { return }
            for line in boundedCatchUpLines() {
                consume(line: line, generation: activeGeneration)
            }
        }
    }

    func stop() {
        let tailer = self.tailer
        self.tailer = nil
        tailer?.stop()

        stateQueue.sync {
            guard isRunning else { return }
            isRunning = false
            phase = .stopped
            generation &+= 1
            pendingAnnouncements.values.forEach { $0.cancel() }
            pendingAnnouncements.removeAll()
            statesByCallID.removeAll()
            callOrder.removeAll()
        }
    }

    func healthSnapshot() -> HealthSnapshot {
        stateQueue.sync {
            HealthSnapshot(
                phase: phase,
                rolloutName: fileURL.lastPathComponent,
                linesObserved: linesObserved,
                structuredRecordsObserved: structuredRecordsObserved,
                pendingPromptCount: statesByCallID.values.reduce(into: 0) { count, state in
                    switch state {
                    case .pending, .announced:
                        count += 1
                    case .completed:
                        break
                    }
                },
                lastStructuredRecordAt: lastStructuredRecordAt
            )
        }
    }

    deinit {
        tailer?.stop()
    }

    private func enqueue(line: String, generation: UInt64) {
        stateQueue.async { [weak self] in
            guard let self, isCurrent(generation) else { return }
            consume(line: line, generation: generation)
        }
    }

    private func consume(line: String, generation: UInt64) {
        linesObserved += 1
        guard let record = CodexRolloutFeedbackParser.parse(line: line) else { return }

        switch record {
        case .structuredPrompt(let prompt):
            guard let callID = prompt.callID,
                  statesByCallID[callID] == nil else {
                return
            }
            recordStructuredActivity()
            statesByCallID[callID] = .pending(prompt)
            callOrder.append(callID)
            scheduleAnnouncement(for: prompt, callID: callID, generation: generation)

        case .toolCallCompleted(let callID, _):
            let priorState = statesByCallID[callID]
            if case .completed = priorState {
                return
            }
            recordStructuredActivity()
            pendingAnnouncements.removeValue(forKey: callID)?.cancel()
            if priorState == nil {
                callOrder.append(callID)
            }
            statesByCallID[callID] = .completed

            if case .announced = priorState {
                let hasOtherPendingPrompt = statesByCallID.values.contains { state in
                    switch state {
                    case .pending, .announced:
                        return true
                    case .completed:
                        return false
                    }
                }
                deliverResolution(
                    callID: callID,
                    hasOtherPendingPrompt: hasOtherPendingPrompt,
                    generation: generation
                )
            }
        }

        pruneCompletedCallsIfNeeded()
    }

    private func recordStructuredActivity() {
        structuredRecordsObserved += 1
        lastStructuredRecordAt = Date()
    }

    private func scheduleAnnouncement(
        for prompt: CodexFeedbackPrompt,
        callID: String,
        generation: UInt64
    ) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  isCurrent(generation),
                  case .pending = statesByCallID[callID] else {
                return
            }
            pendingAnnouncements.removeValue(forKey: callID)
            statesByCallID[callID] = .announced(prompt)
            deliverPrompt(prompt, generation: generation)
        }
        pendingAnnouncements[callID] = workItem
        stateQueue.asyncAfter(deadline: .now() + debounceSeconds, execute: workItem)
    }

    private func deliverPrompt(_ prompt: CodexFeedbackPrompt, generation: UInt64) {
        callbackQueue.async { [weak self] in
            guard let self, isGenerationActive(generation) else { return }
            onPrompt(prompt)
        }
    }

    private func deliverResolution(
        callID: String,
        hasOtherPendingPrompt: Bool,
        generation: UInt64
    ) {
        callbackQueue.async { [weak self] in
            guard let self, isGenerationActive(generation) else { return }
            onResolution(callID, hasOtherPendingPrompt)
        }
    }

    private func isGenerationActive(_ value: UInt64) -> Bool {
        stateQueue.sync { isCurrent(value) }
    }

    private func isCurrent(_ value: UInt64) -> Bool {
        isRunning && generation == value
    }

    private func boundedCatchUpLines() -> [String] {
        guard catchUpLineLimit > 0,
              let reading = BoundedTranscriptReader.read(at: fileURL) else {
            return []
        }
        return Array(reading.text
            .split(whereSeparator: { $0.isNewline })
            .suffix(catchUpLineLimit)
            .map(String.init))
    }

    /// A long-running Codex thread can contain thousands of completed tool
    /// calls. Keep only the latest completed ids while never evicting a live
    /// pending or announced prompt.
    private func pruneCompletedCallsIfNeeded() {
        let retainedLimit = 1_024
        guard callOrder.count > retainedLimit else { return }

        var retained: [String] = []
        retained.reserveCapacity(retainedLimit)
        for callID in callOrder.reversed() {
            switch statesByCallID[callID] {
            case .pending, .announced:
                retained.append(callID)
            case .completed:
                if retained.count < retainedLimit {
                    retained.append(callID)
                } else {
                    statesByCallID.removeValue(forKey: callID)
                }
            case nil:
                break
            }
        }
        callOrder = retained.reversed()
    }
}
