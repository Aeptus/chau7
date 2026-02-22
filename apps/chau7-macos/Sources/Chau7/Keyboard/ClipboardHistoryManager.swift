import Foundation
import AppKit

// MARK: - F16: Clipboard History Manager

/// Manages clipboard history with automatic polling and duplicate detection
final class ClipboardHistoryManager: ObservableObject {
    static let shared = ClipboardHistoryManager()

    @Published private(set) var items: [ClipboardItem] = []

    /// Synchronization lock for thread-safe access to lastChangeCount
    private let lock = NSLock()
    private var lastChangeCount: Int = 0
    private var pollTimer: DispatchSourceTimer?

    struct ClipboardItem: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let timestamp: Date
        var isPinned: Bool = false

        var preview: String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count <= 60 {
                return trimmed.replacingOccurrences(of: "\n", with: " ")
            }
            return String(trimmed.prefix(57)).replacingOccurrences(of: "\n", with: " ") + "..."
        }
    }

    private init() {
        lastChangeCount = NSPasteboard.general.changeCount
        startPolling()
    }

    func startPolling() {
        guard FeatureSettings.shared.isClipboardHistoryEnabled else {
            stopPolling()
            return
        }

        pollTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(
            deadline: .now() + AppConstants.Intervals.clipboardPoll,
            repeating: AppConstants.Intervals.clipboardPoll
        )
        timer.setEventHandler { [weak self] in
            self?.checkClipboard()
        }
        timer.resume()
        pollTimer = timer
    }

    func stopPolling() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    private func checkClipboard() {
        let pasteboard = NSPasteboard.general
        let currentCount = pasteboard.changeCount

        // Thread-safe check and update of lastChangeCount
        // Keep lock held during comparison to prevent TOCTOU race condition
        lock.lock()
        guard currentCount != lastChangeCount else {
            lock.unlock()
            return
        }
        lastChangeCount = currentCount
        lock.unlock()

        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }

        DispatchQueue.main.async { [weak self] in
            self?.addItem(text)
        }
    }

    private func addItem(_ text: String) {
        // Don't add duplicates of the most recent item
        if let existing = items.first, existing.text == text {
            return
        }

        // Remove existing duplicate if present (in-place, no intermediate array)
        if let duplicateIndex = items.firstIndex(where: { $0.text == text && !$0.isPinned }) {
            items.remove(at: duplicateIndex)
        }

        // Add new item at the beginning
        let item = ClipboardItem(text: text, timestamp: Date())
        items.insert(item, at: 0)

        // Trim to max efficiently (in-place removal from end)
        let maxItems = FeatureSettings.shared.clipboardHistoryMaxItems
        trimToMaxItems(maxItems)
    }

    /// Single-pass trimming: collects unpinned indices, removes excess from the end
    private func trimToMaxItems(_ maxItems: Int) {
        guard items.count > maxItems else { return }

        let pinnedCount = items.reduce(0) { $0 + ($1.isPinned ? 1 : 0) }
        let maxUnpinned = max(0, maxItems - pinnedCount)

        // Collect indices of all unpinned items
        var unpinnedIndices: [Int] = []
        for (i, item) in items.enumerated() {
            if !item.isPinned {
                unpinnedIndices.append(i)
            }
        }

        // Remove excess unpinned from the end (oldest = highest indices first)
        let toRemove = max(0, unpinnedIndices.count - maxUnpinned)
        if toRemove > 0 {
            let removeSet = unpinnedIndices.suffix(toRemove)
            // Remove in reverse order to preserve indices
            for idx in removeSet.reversed() {
                items.remove(at: idx)
            }
        }
    }

    func paste(_ item: ClipboardItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.text, forType: .string)

        // Thread-safe update of lastChangeCount
        lock.lock()
        lastChangeCount = pasteboard.changeCount
        lock.unlock()

        // Move to top if not pinned
        if !item.isPinned, let index = items.firstIndex(where: { $0.id == item.id }) {
            items.remove(at: index)
            items.insert(item, at: 0)
        }
    }

    func togglePin(_ item: ClipboardItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].isPinned.toggle()
    }

    func remove(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
    }

    func clear() {
        items.removeAll { !$0.isPinned }
    }
}
