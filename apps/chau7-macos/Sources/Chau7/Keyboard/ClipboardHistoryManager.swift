import Foundation
import AppKit

// MARK: - F16: Clipboard History Manager

/// Manages clipboard history with automatic polling and duplicate detection
@Observable
final class ClipboardHistoryManager {
    static let shared = ClipboardHistoryManager()

    private(set) var items: [ClipboardItem] = []

    /// Synchronization lock for thread-safe access to lastChangeCount
    private let lock = NSLock()
    private var lastChangeCount = 0
    private var pollTimer: DispatchSourceTimer?

    struct ClipboardItem: Identifiable, Equatable, Codable {
        let id: UUID
        let text: String
        let timestamp: Date
        var isPinned = false

        init(text: String, timestamp: Date, isPinned: Bool = false) {
            self.id = UUID()
            self.text = text
            self.timestamp = timestamp
            self.isPinned = isPinned
        }

        var preview: String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count <= 60 {
                return trimmed.replacingOccurrences(of: "\n", with: " ")
            }
            return String(trimmed.prefix(57)).replacingOccurrences(of: "\n", with: " ") + "..."
        }
    }

    private static let persistenceKey = "clipboard.history"

    private var appActiveObservers: [NSObjectProtocol] = []
    private var isAppActive = true

    private init() {
        self.lastChangeCount = NSPasteboard.general.changeCount
        self.isAppActive = NSApp?.isActive ?? true
        loadFromDisk()
        observeAppActivation()
        startPolling()
    }

    private func observeAppActivation() {
        let center = NotificationCenter.default
        appActiveObservers.append(
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self, !self.isAppActive else { return }
                isAppActive = true
                restartPollingWithCurrentInterval()
            }
        )
        appActiveObservers.append(
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self, isAppActive else { return }
                isAppActive = false
                restartPollingWithCurrentInterval()
            }
        )
    }

    private var currentPollInterval: TimeInterval {
        isAppActive
            ? AppConstants.Intervals.clipboardPoll
            : AppConstants.Intervals.clipboardPollBackground
    }

    private var currentPollLeeway: DispatchTimeInterval {
        isAppActive ? .milliseconds(500) : .seconds(2)
    }

    func startPolling() {
        guard FeatureSettings.shared.isClipboardHistoryEnabled else {
            stopPolling()
            return
        }
        restartPollingWithCurrentInterval()
    }

    private func restartPollingWithCurrentInterval() {
        guard FeatureSettings.shared.isClipboardHistoryEnabled else { return }
        pollTimer?.cancel()
        let interval = currentPollInterval
        let leeway = currentPollLeeway
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: leeway)
        timer.setEventHandler { [weak self] in
            Log.wakeup("clipboard")
            // NSPasteboard is not thread-safe and must be read on the main thread.
            // Reading it from this background utility queue races AppKit's pasteboard
            // type cache and crashes in objc_msgSend (EXC_BAD_ACCESS). Marshal the
            // whole poll to main; the changeCount guard keeps it cheap.
            DispatchQueue.main.async { self?.checkClipboard() }
        }
        timer.resume()
        pollTimer = timer
    }

    func stopPolling() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    /// Polls the system pasteboard for new text. Must run on the main thread —
    /// `NSPasteboard` is not thread-safe (the timer handler dispatches here).
    private func checkClipboard() {
        let pasteboard = NSPasteboard.general
        let currentCount = pasteboard.changeCount

        lock.lock()
        guard currentCount != lastChangeCount else {
            lock.unlock()
            return
        }
        lastChangeCount = currentCount
        lock.unlock()

        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }

        // Already on the main thread; `addItem` mutates the observable `items`.
        addItem(text)
    }

    /// Per-item storage cap. History persists into the UserDefaults plist —
    /// a copied multi-MB log went straight into prefs (the exact bloat class
    /// the scrollback-stripped restore index evicted). Oversized payloads are
    /// truncated for history; the live pasteboard still holds the full text.
    private static let maxStoredTextBytes = 100 * 1024

    private func addItem(_ text: String) {
        var text = text
        if text.utf8.count > Self.maxStoredTextBytes {
            let prefixBytes = Array(text.utf8.prefix(Self.maxStoredTextBytes))
            text = String(decoding: prefixBytes, as: UTF8.self) + "\u{2026}"
        }

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
        persistToDisk()
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

        // Move to top if not pinned — and persist, or the reorder silently
        // reverts on relaunch (in-memory vs persisted divergence).
        if !item.isPinned, let index = items.firstIndex(where: { $0.id == item.id }) {
            items.remove(at: index)
            items.insert(item, at: 0)
            persistToDisk()
        }
    }

    func togglePin(_ item: ClipboardItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].isPinned.toggle()
        persistToDisk()
    }

    func remove(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
        persistToDisk()
    }

    func clear() {
        items.removeAll { !$0.isPinned }
        persistToDisk()
    }

    // MARK: - Search

    func search(query: String) -> [ClipboardItem] {
        let lowered = query.lowercased()
        return items.filter { $0.text.lowercased().contains(lowered) }
    }

    // MARK: - Persistence

    private func persistToDisk() {
        guard let data = Persist.encodeLogged(items, context: "clipboardHistory") else { return }
        UserDefaults.standard.set(data, forKey: Self.persistenceKey)
    }

    private func loadFromDisk() {
        guard let saved = Persist.decodeLogged(
            [ClipboardItem].self,
            from: UserDefaults.standard.data(forKey: Self.persistenceKey),
            context: "clipboardHistory"
        ) else { return }
        items = saved
    }
}
