import Foundation
import Chau7Core

/// Per-tab UTF-8 output accumulator with flush threshold and snapshot support.
///
/// Buffers incoming terminal output per tab ID. Flushes when pending data
/// exceeds 50 KB or after a 250 ms debounce. Snapshots replace the entire
/// tab output atomically (used when switching tabs or receiving grid state).
struct RemoteTerminalOutputStore {
    private var committedByTabID: [UInt32: String] = [:]
    private var pendingByTabID = RemotePendingOutputBuffer<String>()

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
    }

    mutating func retainVisibleTabs(_ visibleTabIDs: Set<UInt32>) {
        committedByTabID = committedByTabID.filter { visibleTabIDs.contains($0.key) }
        pendingByTabID.retain(only: visibleTabIDs)
    }

    mutating func append(_ data: Data, to tabID: UInt32) {
        let text = String(decoding: RemoteOutputTuning.capIncomingFrame(data), as: UTF8.self)
        pendingByTabID.append(text, to: tabID) { existing, chunk in
            existing.append(chunk)
        }
    }

    mutating func replaceSnapshot(_ data: Data, for tabID: UInt32) {
        let text = String(decoding: RemoteOutputTuning.capSnapshot(data), as: UTF8.self)
        pendingByTabID.drain(tabID: tabID)
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
            let committed = committedByTabID[targetTabID] ?? ""
            committedByTabID[targetTabID] = RemoteOutputTuning.trimRetainedText(committed + pending)
            updatedTabIDs.insert(targetTabID)
        }
        return updatedTabIDs
    }

    func visibleOutput(for activeTabID: UInt32) -> String {
        let committed = committedByTabID[activeTabID] ?? ""
        if let pending = pendingByTabID[activeTabID], !pending.isEmpty {
            return RemoteOutputTuning.trimRetainedText(committed + pending)
        }
        return committed
    }
}
