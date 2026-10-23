import Foundation

/// Reuses both positive and negative prompt detections until terminal content
/// or input changes. Cache bookkeeping must not be observed as UI state.
public struct RemotePromptDetectionCache {
    public struct Revision: Equatable {
        public let outputVersion: UInt64
        public let lastInputAt: Date
        public let terminalIdentity: ObjectIdentifier?

        public init(outputVersion: UInt64, lastInputAt: Date, terminalIdentity: ObjectIdentifier? = nil) {
            self.outputVersion = outputVersion
            self.lastInputAt = lastInputAt
            self.terminalIdentity = terminalIdentity
        }
    }

    private struct Entry {
        let revision: Revision
        let toolName: String
        let prompt: DetectedInteractivePrompt?
        var lastAccess: UInt64
    }

    private let capacity: Int
    private var entries: [String: Entry] = [:]
    private var access: UInt64 = 0

    public init(capacity: Int = 64) {
        self.capacity = max(1, capacity)
    }

    public mutating func detection(
        sessionID: String,
        revision: Revision,
        toolName: String,
        capture: () -> String?
    ) -> DetectedInteractivePrompt? {
        access &+= 1
        if var entry = entries[sessionID], entry.revision == revision, entry.toolName == toolName {
            entry.lastAccess = access
            entries[sessionID] = entry
            return entry.prompt
        }

        let prompt = capture().flatMap {
            InteractivePromptDetector.detect(in: $0, toolName: toolName)
                ?? InteractivePromptDetector.fallbackInputRequest(in: $0)
        }
        if entries[sessionID] == nil, entries.count >= capacity,
           let oldestID = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
            entries.removeValue(forKey: oldestID)
        }
        entries[sessionID] = Entry(revision: revision, toolName: toolName, prompt: prompt, lastAccess: access)
        return prompt
    }

    public mutating func removeAll() {
        entries.removeAll()
        access = 0
    }
}
