import Foundation

// MARK: - F17: Bookmark Manager

/// Manages terminal bookmarks per tab with configurable limits
final class BookmarkManager: ObservableObject {
    static let shared = BookmarkManager()

    @Published private(set) var bookmarks: [UUID: [Bookmark]] = [:]  // tabID -> bookmarks

    struct Bookmark: Identifiable, Equatable {
        let id = UUID()
        let tabID: UUID
        let scrollOffset: Int  // Row offset in terminal buffer
        let linePreview: String
        let timestamp: Date
        var label: String?
    }

    private init() {}

    func addBookmark(tabID: UUID, scrollOffset: Int, linePreview: String, label: String? = nil) {
        guard FeatureSettings.shared.isBookmarksEnabled else { return }

        var tabBookmarks = bookmarks[tabID] ?? []

        // Check max
        let max = FeatureSettings.shared.maxBookmarksPerTab
        if tabBookmarks.count >= max {
            // Remove oldest non-labeled bookmark
            if let index = tabBookmarks.firstIndex(where: { $0.label == nil }) {
                tabBookmarks.remove(at: index)
            } else {
                tabBookmarks.removeLast()
            }
        }

        let bookmark = Bookmark(
            tabID: tabID,
            scrollOffset: scrollOffset,
            linePreview: String(linePreview.prefix(80)),
            timestamp: Date(),
            label: label
        )
        tabBookmarks.append(bookmark)
        bookmarks[tabID] = tabBookmarks
    }

    func removeBookmark(_ bookmark: Bookmark) {
        var tabBookmarks = bookmarks[bookmark.tabID] ?? []
        tabBookmarks.removeAll { $0.id == bookmark.id }
        bookmarks[bookmark.tabID] = tabBookmarks
    }

    func getBookmarks(for tabID: UUID) -> [Bookmark] {
        return bookmarks[tabID] ?? []
    }

    func clearBookmarks(for tabID: UUID) {
        bookmarks[tabID] = []
    }
}
