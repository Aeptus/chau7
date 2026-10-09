import Foundation
import Chau7Core

/// Tails provider-owned JSONL files for completed output usage. Providers
/// write exact output-token counts but do not expose a live token stream here,
/// so these readings use transcript timestamps and are explicitly estimates.
final class LiveTokenRateMonitor: @unchecked Sendable {
    enum ProviderKind: Sendable {
        case claude
        case codex

        var displayName: String {
            return switch self {
            case .claude: "Claude"
            case .codex: "Codex"
            }
        }

        var source: TokenRateSource {
            return switch self {
            case .claude: .claudeTranscript
            case .codex: .codexTranscript
            }
        }
    }

    private struct FileState {
        var lastUserAt: Date?
        var lastAssistantAt: Date?
        var codexTurnStartedAt: Date?
        var lastCodexUsageAt: Date?
        var model: String?
        var seenUsageKeys: Set<String> = []
        var usageKeyOrder: [String] = []
    }

    private let tabID: String
    private let provider: ProviderKind
    private var tailers: [(path: String, tailer: FileTailer<String>)] = []
    private let lock = NSLock()
    private var fileStates: [String: FileState] = [:]
    private var isActive = false

    init(tabID: String, provider: ProviderKind, files: [URL]) {
        self.tabID = tabID
        self.provider = provider
        self.tailers = files.map { file in
            let path = file.path
            let tailer = FileTailer<String>(
                fileURL: file,
                pollInterval: .milliseconds(200),
                createIfMissing: false,
                queueLabel: "com.chau7.token-rate.\(UUID().uuidString)",
                parser: { $0 },
                onItem: { [weak self] line in
                    self?.consume(line: line, path: path)
                }
            )
            return (path, tailer)
        }
    }

    func start() {
        lock.lock()
        isActive = true
        lock.unlock()
        for item in tailers {
            item.tailer.start(prefillLines: 200)
        }
    }

    func stop() {
        lock.lock()
        isActive = false
        lock.unlock()
        tailers.forEach { $0.tailer.stop() }
    }

    private func consume(line: String, path: String) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let reading: (model: String?, outputTokens: Int, durationMs: Int, at: Date)?
        lock.lock()
        guard isActive else {
            lock.unlock()
            return
        }
        var state = fileStates[path, default: FileState()]
        switch provider {
        case .claude:
            reading = consumeClaude(object: object, state: &state)
        case .codex:
            reading = consumeCodex(object: object, state: &state)
        }
        fileStates[path] = state
        lock.unlock()

        guard let reading else { return }
        Task { @MainActor in
            TokenRateStore.shared.record(
                tabID: tabID,
                provider: reading.model.map { "\(provider.displayName) · \($0)" } ?? provider.displayName,
                outputTokens: reading.outputTokens,
                durationMs: reading.durationMs,
                source: provider.source,
                updatedAt: reading.at
            )
        }
    }

    private func consumeClaude(
        object: [String: Any],
        state: inout FileState
    ) -> (model: String?, outputTokens: Int, durationMs: Int, at: Date)? {
        guard let timestamp = ClaudeTranscriptUsageParser.parseDate(object["timestamp"] as? String),
              let message = object["message"] as? [String: Any] else { return nil }

        let role = (message["role"] as? String) ?? (object["type"] as? String) ?? ""
        if role == "user" {
            if containsToolResult(message["content"]) {
                state.lastAssistantAt = timestamp
            } else {
                state.lastUserAt = timestamp
                state.lastAssistantAt = nil
            }
            return nil
        }
        guard role == "assistant" else { return nil }

        if let model = message["model"] as? String, !model.isEmpty {
            state.model = model
        }
        let outputTokens = (message["usage"] as? [String: Any])?["output_tokens"] as? Int ?? 0
        let usageKey = ClaudeTranscriptUsageParser.requestUsageKey(obj: object, message: message)
            ?? "\(timestamp.timeIntervalSince1970)-\(outputTokens)"
        let isNewUsage = outputTokens > 0 && remember(usageKey, state: &state)
        let startAt = state.lastAssistantAt ?? state.lastUserAt
        state.lastAssistantAt = timestamp

        guard isNewUsage, outputTokens > 0,
              let startAt,
              let durationMs = validDuration(from: startAt, to: timestamp) else { return nil }
        return (state.model, outputTokens, durationMs, timestamp)
    }

    private func consumeCodex(
        object: [String: Any],
        state: inout FileState
    ) -> (model: String?, outputTokens: Int, durationMs: Int, at: Date)? {
        let type = object["type"] as? String ?? ""
        let payload = object["payload"] as? [String: Any] ?? [:]
        let timestamp = CodexRolloutParser.parseDate(object["timestamp"] as? String)

        if type == "turn_context" {
            state.codexTurnStartedAt = timestamp
            state.lastCodexUsageAt = nil
            if let model = payload["model"] as? String, !model.isEmpty {
                state.model = model
            }
            return nil
        }

        guard type == "event_msg",
              (payload["type"] as? String) == "token_count",
              let timestamp,
              let info = payload["info"] as? [String: Any],
              let usage = info["last_token_usage"] as? [String: Any] else { return nil }

        let outputTokens = usage["output_tokens"] as? Int ?? 0
        guard outputTokens > 0 else { return nil }
        let startAt = state.lastCodexUsageAt ?? state.codexTurnStartedAt
        state.lastCodexUsageAt = timestamp
        guard let startAt,
              let durationMs = validDuration(from: startAt, to: timestamp) else { return nil }
        return (state.model, outputTokens, durationMs, timestamp)
    }

    private func remember(_ key: String, state: inout FileState) -> Bool {
        guard state.seenUsageKeys.insert(key).inserted else { return false }
        state.usageKeyOrder.append(key)
        if state.usageKeyOrder.count > 512 {
            let evicted = state.usageKeyOrder.removeFirst()
            state.seenUsageKeys.remove(evicted)
        }
        return true
    }

    private func containsToolResult(_ content: Any?) -> Bool {
        guard let blocks = content as? [[String: Any]] else { return false }
        return blocks.contains { ($0["type"] as? String) == "tool_result" }
    }

    private func validDuration(from start: Date, to end: Date) -> Int? {
        let durationMs = Int(end.timeIntervalSince(start) * 1000)
        guard (250 ... 300_000).contains(durationMs) else { return nil }
        return durationMs
    }
}
