import XCTest
@testable import Chau7

@MainActor
final class ClipboardHistoryManagerTests: XCTestCase {

    private var manager: ClipboardHistoryManager!
    private var savedItems: [ClipboardHistoryManager.ClipboardItem] = []
    private var savedMaxItems = 50
    private var savedPersistedData: Data?
    private var savedPasteboardString: String?

    override func setUp() {
        super.setUp()
        manager = ClipboardHistoryManager.shared
        // Stop polling so tests are deterministic
        manager.stopPolling()
        // Save existing state. `addItem`/`paste`/`togglePin`/... persist to
        // UserDefaults ("clipboard.history"), so snapshot the raw blob too.
        savedItems = manager.items
        savedMaxItems = FeatureSettings.shared.clipboardHistoryMaxItems
        savedPersistedData = UserDefaults.standard.data(forKey: "clipboard.history")
        savedPasteboardString = NSPasteboard.general.string(forType: .string)
        // Clear items for a clean slate
        manager.replaceItemsForTesting([])
    }

    override func tearDown() {
        // Restore previous state (in-memory, persisted blob, and pasteboard)
        manager.replaceItemsForTesting(savedItems)
        FeatureSettings.shared.clipboardHistoryMaxItems = savedMaxItems
        if let savedPersistedData {
            UserDefaults.standard.set(savedPersistedData, forKey: "clipboard.history")
        } else {
            UserDefaults.standard.removeObject(forKey: "clipboard.history")
        }
        if let savedPasteboardString {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(savedPasteboardString, forType: .string)
        }
        super.tearDown()
    }

    // MARK: - addItem

    func testAddItem() {
        manager.addItemForTesting("hello")
        XCTAssertEqual(manager.items.count, 1)
        XCTAssertEqual(manager.items.first?.text, "hello")
    }

    func testOversizedItemIsTruncatedForStorage() {
        // Items above the 100KB per-item cap are truncated (with an ellipsis)
        // before being stored, so multi-MB copies don't bloat the prefs plist.
        let oversized = String(repeating: "x", count: 150 * 1024)
        manager.addItemForTesting(oversized)

        let stored = manager.items.first?.text ?? ""
        XCTAssertLessThanOrEqual(
            stored.utf8.count,
            100 * 1024 + "\u{2026}".utf8.count,
            "Stored item should be capped at 100KB plus the ellipsis"
        )
        XCTAssertTrue(stored.hasSuffix("\u{2026}"), "Truncated item should end with an ellipsis")
    }

    // MARK: - Duplicate Handling

    func testAddDuplicateMovesToTop() {
        manager.addItemForTesting("first")
        manager.addItemForTesting("second")
        manager.addItemForTesting("first")

        XCTAssertEqual(manager.items.count, 2, "Duplicate should be removed, not appended")
        XCTAssertEqual(manager.items[0].text, "first", "Duplicate should move to top")
        XCTAssertEqual(manager.items[1].text, "second")
    }

    // MARK: - Trimming

    func testTrimToMaxItems() {
        FeatureSettings.shared.clipboardHistoryMaxItems = 3

        for i in 0 ..< 5 {
            manager.addItemForTesting("item-\(i)")
        }

        XCTAssertLessThanOrEqual(
            manager.items.count,
            3,
            "Items should be trimmed to maxItems"
        )
        XCTAssertEqual(
            manager.items[0].text,
            "item-4",
            "Most recent item should be at the top"
        )
    }

    // MARK: - Pinned Items Survive Trim

    func testPinnedItemsSurviveTrim() {
        FeatureSettings.shared.clipboardHistoryMaxItems = 3

        manager.addItemForTesting("pinned-item")
        manager.togglePin(manager.items[0])

        // Fill beyond max with unpinned items
        for i in 0 ..< 5 {
            manager.addItemForTesting("filler-\(i)")
        }

        let pinnedItems = manager.items.filter { $0.isPinned }
        XCTAssertEqual(pinnedItems.count, 1, "Pinned item should survive trimming")
        XCTAssertEqual(pinnedItems.first?.text, "pinned-item")
    }

    // MARK: - Toggle Pin

    func testTogglePin() {
        manager.addItemForTesting("test")
        let item = manager.items[0]

        XCTAssertFalse(item.isPinned, "Item should start unpinned")

        manager.togglePin(item)
        XCTAssertTrue(manager.items[0].isPinned, "Item should be pinned after toggle")

        manager.togglePin(manager.items[0])
        XCTAssertFalse(manager.items[0].isPinned, "Item should be unpinned after second toggle")
    }

    // MARK: - Paste

    func testPaste() {
        manager.addItemForTesting("first")
        manager.addItemForTesting("second")
        manager.addItemForTesting("third")

        // Paste the last item (index 2 = "first")
        let itemToPaste = manager.items[2]
        manager.paste(itemToPaste)

        XCTAssertEqual(
            manager.items[0].text,
            itemToPaste.text,
            "Pasted item should move to top"
        )

        let pasteboard = NSPasteboard.general
        XCTAssertEqual(
            pasteboard.string(forType: .string),
            itemToPaste.text,
            "Pasteboard should contain the pasted text"
        )
    }

    // MARK: - Remove

    func testRemove() {
        manager.addItemForTesting("keep")
        manager.addItemForTesting("remove-me")

        let toRemove = manager.items.first(where: { $0.text == "remove-me" })!
        manager.remove(toRemove)

        XCTAssertEqual(manager.items.count, 1)
        XCTAssertNil(
            manager.items.first(where: { $0.text == "remove-me" }),
            "Removed item should not be present"
        )
        XCTAssertNotNil(
            manager.items.first(where: { $0.text == "keep" }),
            "Non-removed item should remain"
        )
    }

    // MARK: - Clear

    func testClear() {
        manager.addItemForTesting("pinned")
        manager.togglePin(manager.items[0])

        manager.addItemForTesting("unpinned-1")
        manager.addItemForTesting("unpinned-2")

        manager.clear()

        XCTAssertEqual(manager.items.count, 1, "Only pinned items should survive clear")
        XCTAssertEqual(manager.items[0].text, "pinned")
        XCTAssertTrue(manager.items[0].isPinned)
    }

    // MARK: - Preview

    func testPreview() {
        // Short text should be returned as-is (trimmed, newlines replaced)
        let shortItem = ClipboardHistoryManager.ClipboardItem(
            text: "short text",
            timestamp: Date()
        )
        XCTAssertEqual(shortItem.preview, "short text")

        // Newlines in short text should become spaces
        let multilineShort = ClipboardHistoryManager.ClipboardItem(
            text: "line1\nline2",
            timestamp: Date()
        )
        XCTAssertEqual(multilineShort.preview, "line1 line2")

        // Long text (>60 chars) should be truncated with "..."
        let longText = String(repeating: "a", count: 100)
        let longItem = ClipboardHistoryManager.ClipboardItem(
            text: longText,
            timestamp: Date()
        )
        XCTAssertTrue(
            longItem.preview.hasSuffix("..."),
            "Long preview should end with ellipsis"
        )
        XCTAssertEqual(
            longItem.preview.count,
            60,
            "Long preview should be exactly 60 characters (57 + '...')"
        )
    }
}
