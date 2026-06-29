import Foundation
import Chau7Core

// MARK: - Runbook Code Block Types

/// Composite key for a markdown runbook code block. Line number + normalized
/// command together identify a block uniquely even if the same `echo hello`
/// shows up multiple times in the file.
struct RunbookCodeBlockKey: Hashable {
    let lineNumber: Int
    let normalizedCommand: String
}

/// Terminal state for a tracked runbook code block.
enum RunbookCodeBlockState {
    case running
    case succeeded
    case failed
}

// MARK: - Tracker

/// Owns runbook code-block state and the markdown-runbook sequential runner
/// extracted from `TextEditorModel`. The model held five distinct concerns
/// (file buffer + dirty tracking + autosave debounce + external-change
/// detection + runbook state machine); pulling the runbook out leaves the
/// model with file-buffer responsibilities only.
///
/// The tracker is `@Observable` so the SwiftUI runbook view stays reactive
/// to `codeBlockRunStates` mutations. The mainScheduler is overridable for
/// unit tests; production keeps the default `SystemMainScheduler`.
@Observable
final class RunbookCodeBlockTracker {
    /// Per-block terminal state. Observed by `MarkdownRunbookView` to colour
    /// each code block's border.
    var codeBlockRunStates: [RunbookCodeBlockKey: RunbookCodeBlockState] = [:]

    @ObservationIgnored
    private var pendingPollWorkItems: [RunbookCodeBlockKey: DispatchWorkItem] = [:]
    @ObservationIgnored
    private var executionGenerations: [RunbookCodeBlockKey: Int] = [:]
    @ObservationIgnored
    var mainScheduler: MainScheduler = SystemMainScheduler()

    deinit {
        for workItem in pendingPollWorkItems.values {
            workItem.cancel()
        }
    }

    // MARK: - Per-block tracking

    /// Marks the named block as queued/running and starts a poll loop that
    /// transitions it to `.succeeded` / `.failed` based on the matching
    /// `CommandBlockManager` entry. Generation counters prevent a stale
    /// poll from a previous run from overwriting the current state.
    func markCodeBlockQueued(_ code: String, lineNumber: Int, tabID: String) {
        let key = Self.runbookCodeBlockKey(for: code, lineNumber: lineNumber)
        codeBlockRunStates[key] = .running
        pendingPollWorkItems[key]?.cancel()
        let generation = (executionGenerations[key] ?? 0) + 1
        executionGenerations[key] = generation
        let submittedAt = Date()
        pollForCommandCompletion(
            command: code,
            key: key,
            generation: generation,
            tabID: tabID,
            submittedAt: submittedAt,
            attemptsRemaining: 120
        )
    }

    /// Current state for a tracked block, or nil if it was never queued.
    func codeBlockState(for code: String, lineNumber: Int) -> RunbookCodeBlockState? {
        codeBlockRunStates[Self.runbookCodeBlockKey(for: code, lineNumber: lineNumber)]
    }

    // MARK: - Sequential runner

    /// Send a list of markdown code blocks to the terminal one at a time,
    /// waiting for each to settle (`.succeeded` / `.failed`) before sending
    /// the next. `send` forwards the block to the shell and is responsible
    /// for calling `markCodeBlockQueued` (typically via
    /// `SplitPaneController.sendCommandToTerminal`). A block that never
    /// reports a terminal state gives up after ~60s and stops the queue.
    func runMarkdownBlocksSequentially(
        _ blocks: [(line: Int, code: String)],
        send: @escaping (String, Int) -> Void
    ) {
        sendNextMarkdownBlock(blocks: blocks, index: 0, send: send)
    }

    private func sendNextMarkdownBlock(
        blocks: [(line: Int, code: String)],
        index: Int,
        send: @escaping (String, Int) -> Void
    ) {
        guard index < blocks.count else { return }
        let block = blocks[index]
        send("\(block.code)\n", block.line)
        Polling.untilTrue(
            on: mainScheduler,
            predicate: { [weak self] in
                guard let self else { return true }
                switch codeBlockState(for: block.code, lineNumber: block.line) {
                case .succeeded, .failed: return true
                case .running, .none: return false
                }
            },
            onSettled: { [weak self] in
                self?.sendNextMarkdownBlock(blocks: blocks, index: index + 1, send: send)
            }
        )
    }

    // MARK: - Internal poll

    private func pollForCommandCompletion(
        command: String,
        key: RunbookCodeBlockKey,
        generation: Int,
        tabID: String,
        submittedAt: Date,
        attemptsRemaining: Int
    ) {
        guard attemptsRemaining > 0 else {
            codeBlockRunStates[key] = .failed
            pendingPollWorkItems.removeValue(forKey: key)
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let block = MainActor.assumeIsolated {
                CommandBlockManager.shared.blocksForTab(tabID)
            }.reversed().first { candidate in
                candidate.startTime >= submittedAt.addingTimeInterval(-1)
                    && Self.normalizedRunbookKey(for: candidate.command) == key.normalizedCommand
            }
            guard executionGenerations[key] == generation else {
                pendingPollWorkItems.removeValue(forKey: key)
                return
            }
            if let block, !block.isRunning {
                codeBlockRunStates[key] = block.isSuccess ? .succeeded : .failed
                pendingPollWorkItems.removeValue(forKey: key)
                return
            }
            pollForCommandCompletion(
                command: command,
                key: key,
                generation: generation,
                tabID: tabID,
                submittedAt: submittedAt,
                attemptsRemaining: attemptsRemaining - 1
            )
        }
        pendingPollWorkItems[key] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    // MARK: - Key helpers

    static func normalizedRunbookKey(for command: String) -> String {
        command.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func runbookCodeBlockKey(for command: String, lineNumber: Int) -> RunbookCodeBlockKey {
        RunbookCodeBlockKey(
            lineNumber: lineNumber,
            normalizedCommand: normalizedRunbookKey(for: command)
        )
    }
}
