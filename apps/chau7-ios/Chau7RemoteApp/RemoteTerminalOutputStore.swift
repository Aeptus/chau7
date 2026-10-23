import Chau7Core
import Foundation

/// Per-tab UTF-8 output accumulator with flush threshold and snapshot support.
///
/// Buffers incoming terminal output per tab ID. Flushes when pending data
/// reaches the shared cap or on the plain-text display cadence. Snapshots replace the entire
/// tab output atomically (used when switching tabs or receiving grid state).
struct RemoteTerminalOutputStore {
    /// Committed text may overshoot the retained cap by this much before it
    /// is trimmed. Once a tab's buffer is full, trimming on every flush
    /// re-copied the whole tail every 16 ms on the main actor, even while the
    /// rich renderer was on screen and nothing read the text. With the slack
    /// a flush appends in place, and a trim runs once per 32 KB of output.
    static let trimSlackBytes = 32768

    private var committedByTabID: [UInt32: String] = [:]
    private var pendingByTabID = RemotePendingOutputBuffer<String>()
    /// UTF-8 scalars may be split across arbitrary PTY/WebSocket frames. Keep
    /// only an incomplete, valid suffix until the next chunk completes it.
    private var incompleteUTF8ByTabID: [UInt32: Data] = [:]

    var hasPendingOutput: Bool {
        !pendingByTabID.isEmpty
    }

    func hasPendingOutput(for tabID: UInt32) -> Bool {
        pendingByTabID[tabID] != nil
    }

    func pendingByteCount(for tabID: UInt32) -> Int {
        pendingByTabID[tabID]?.utf8.count ?? 0
    }

    mutating func reset() {
        committedByTabID.removeAll()
        pendingByTabID.removeAll(keepingCapacity: true)
        incompleteUTF8ByTabID.removeAll(keepingCapacity: true)
    }

    mutating func retainVisibleTabs(_ visibleTabIDs: Set<UInt32>) {
        committedByTabID = committedByTabID.filter { visibleTabIDs.contains($0.key) }
        pendingByTabID.retain(only: visibleTabIDs)
        incompleteUTF8ByTabID = incompleteUTF8ByTabID.filter { visibleTabIDs.contains($0.key) }
    }

    mutating func append(_ data: Data, to tabID: UInt32) {
        let chunk = RemoteOutputTuning.capIncomingFrame(data)
        guard !chunk.isEmpty else { return }

        var bytes = incompleteUTF8ByTabID.removeValue(forKey: tabID) ?? Data()
        bytes.append(chunk)
        let completeCount = Self.incompleteUTF8SuffixStart(in: bytes) ?? bytes.count
        let text = String(decoding: bytes.prefix(completeCount), as: UTF8.self)
        if completeCount < bytes.count {
            incompleteUTF8ByTabID[tabID] = Data(bytes.suffix(bytes.count - completeCount))
        }
        guard !text.isEmpty else { return }
        pendingByTabID.append(text, to: tabID) { existing, chunk in
            existing.append(chunk)
        }
    }

    mutating func replaceSnapshot(_ data: Data, for tabID: UInt32) {
        let text = String(decoding: RemoteOutputTuning.capSnapshot(data), as: UTF8.self)
        pendingByTabID.drain(tabID: tabID)
        incompleteUTF8ByTabID[tabID] = nil
        committedByTabID[tabID] = RemoteOutputTuning.trimRetainedText(text)
    }

    @discardableResult
    mutating func flushPendingOutput(for tabID: UInt32? = nil) -> Set<UInt32> {
        let targetTabIDs: [UInt32]
        if let tabID {
            guard pendingByTabID[tabID] != nil else { return [] }
            targetTabIDs = [tabID]
        } else {
            guard !pendingByTabID.isEmpty else { return [] }
            targetTabIDs = pendingByTabID.tabIDs
        }

        var updatedTabIDs: Set<UInt32> = []
        for targetTabID in targetTabIDs {
            guard let pending = pendingByTabID.drain(tabID: targetTabID), !pending.isEmpty else { continue }
            // Take the value out of the dictionary so the append is in place
            // rather than a copy of the whole retained tail.
            var committed = committedByTabID.removeValue(forKey: targetTabID) ?? ""
            committed.append(pending)
            if committed.utf8.count > RemoteOutputTuning.maxRetainedBytes + Self.trimSlackBytes {
                committed = RemoteOutputTuning.trimRetainedText(committed)
            }
            committedByTabID[targetTabID] = committed
            updatedTabIDs.insert(targetTabID)
        }
        return updatedTabIDs
    }

    /// The displayed tail, exactly within the retained cap. Only the plain
    /// text presentation reads it, so the trim copy is paid only there.
    func visibleOutput(for activeTabID: UInt32) -> String {
        let committed = committedByTabID[activeTabID] ?? ""
        if let pending = pendingByTabID[activeTabID], !pending.isEmpty {
            return RemoteOutputTuning.trimRetainedText(committed + pending)
        }
        return RemoteOutputTuning.trimRetainedText(committed)
    }

    /// Returns the start of a valid but incomplete UTF-8 scalar at the end of
    /// `data`. Malformed bytes are deliberately left in the decoded prefix so
    /// String(decoding:as:) retains its replacement-character behavior.
    private static func incompleteUTF8SuffixStart(in data: Data) -> Int? {
        let bytes = Array(data.suffix(4))
        guard !bytes.isEmpty else { return nil }

        let firstCandidate = max(0, bytes.count - 4)
        var leadIndex = bytes.count - 1
        while leadIndex > firstCandidate, bytes[leadIndex] & 0xC0 == 0x80 {
            leadIndex -= 1
        }

        let lead = bytes[leadIndex]
        let expectedLength: Int
        switch lead {
        case 0xC2 ... 0xDF: expectedLength = 2
        case 0xE0 ... 0xEF: expectedLength = 3
        case 0xF0 ... 0xF4: expectedLength = 4
        default: return nil
        }

        guard bytes.count - leadIndex < expectedLength else { return nil }
        for offset in 1 ..< (bytes.count - leadIndex) {
            let continuation = bytes[leadIndex + offset]
            guard continuation & 0xC0 == 0x80 else { return nil }
            guard offset == 1 else { continue }
            if (lead == 0xE0 && continuation < 0xA0)
                || (lead == 0xED && continuation > 0x9F)
                || (lead == 0xF0 && continuation < 0x90)
                || (lead == 0xF4 && continuation > 0x8F) {
                return nil
            }
        }
        return data.count - bytes.count + leadIndex
    }
}
