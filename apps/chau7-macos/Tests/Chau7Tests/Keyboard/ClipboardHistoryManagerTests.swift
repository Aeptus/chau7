import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7

@MainActor
final class ClipboardHistoryManagerTests: XCTestCase {

    private var manager: ClipboardHistoryManager!
    private var savedItems: [ClipboardHistoryManager.ClipboardItem] = []
    private var savedMaxItems: Int = 50

    override func setUp() {
        super.setUp()
        manager = ClipboardHistoryManager.shared
        // Stop polling so tests are deterministic
        manager.stopPolling()
        // Save existing state
        savedItems = manager.items
        savedMaxItems = FeatureSettings.shared.clipboardHistoryMaxItems
        // Clear items for a clean slate
        manager.items = []
    }

    override func tearDown() {
        // Restore previous state
        manager.items = savedItems
        FeatureSettings.shared.clipboardHistoryMaxItems = savedMaxItems
        super.tearDown()
    }

    // MARK: - addItem

    func testAddItem() {
        manager.addItem("hello")
        XCTAssertEqual(manager.items.count, 1)
        XCTAssertEqual(manager.items.first?.text, "hello")
    }

    // MARK: - Duplicate Handling

    func testAddDuplicateMovesToTop() {
        manager.addItem("first")
        manager.addItem("second")
        manager.addItem("first")

        XCTAssertEqual(manager.items.count, 2, "Duplicate should be removed, not appended")
        XCTAssertEqual(manager.items[0].text, "first", "Duplicate should move to top")
        XCTAssertEqual(manager.items[1].text, "second")
    }

    // MARK: - Trimming

    func testTrimToMaxItems() {
        FeatureSettings.shared.clipboardHistoryMaxItems = 3

        for i in 0..<5 {
            manager.addItem("item-\(i)")
        }

        XCTAssertLessThanOrEqual(manager.items.count, 3,
            "Items should be trimmed to maxItems")
        XCTAssertEqual(manager.items[0].text, "item-4",
            "Most recent item should be at the top")
    }

    // MARK: - Pinned Items Survive Trim

    func testPinnedItemsSurviveTrim() {
        FeatureSettings.shared.clipboardHistoryMaxItems = 3

        manager.addItem("pinned-item")
        manager.togglePin(manager.items[0])

        // Fill beyond max with unpinned items
        for i in 0..<5 {
            manager.addItem("filler-\(i)")
        }

        let pinnedItems = manager.items.filter { $0.isPinned }
        XCTAssertEqual(pinnedItems.count, 1, "Pinned item should survive trimming")
        XCTAssertEqual(pinnedItems.first?.text, "pinned-item")
    }

    // MARK: - Toggle Pin

    func testTogglePin() {
        manager.addItem("test")
        let item = manager.items[0]

        XCTAssertFalse(item.isPinned, "Item should start unpinned")

        manager.togglePin(item)
        XCTAssertTrue(manager.items[0].isPinned, "Item should be pinned after toggle")

        manager.togglePin(manager.items[0])
        XCTAssertFalse(manager.items[0].isPinned, "Item should be unpinned after second toggle")
    }

    // MARK: - Paste

    func testPaste() {
        manager.addItem("first")
        manager.addItem("second")
        manager.addItem("third")

        // Paste the last item (index 2 = "first")
        let itemToPaste = manager.items[2]
        manager.paste(itemToPaste)

        XCTAssertEqual(manager.items[0].text, itemToPaste.text,
            "Pasted item should move to top")

        let pasteboard = NSPasteboard.general
        XCTAssertEqual(pasteboard.string(forType: .string), itemToPaste.text,
            "Pasteboard should contain the pasted text")
    }

    // MARK: - Remove

    func testRemove() {
        manager.addItem("keep")
        manager.addItem("remove-me")

        let toRemove = manager.items.first(where: { $0.text == "remove-me" })!
        manager.remove(toRemove)

        XCTAssertEqual(manager.items.count, 1)
        XCTAssertNil(manager.items.first(where: { $0.text == "remove-me" }),
            "Removed item should not be present")
        XCTAssertNotNil(manager.items.first(where: { $0.text == "keep" }),
            "Non-removed item should remain")
    }

    // MARK: - Clear

    func testClear() {
        manager.addItem("pinned")
        manager.togglePin(manager.items[0])

        manager.addItem("unpinned-1")
        manager.addItem("unpinned-2")

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
        XCTAssertTrue(longItem.preview.hasSuffix("..."),
            "Long preview should end with ellipsis")
        XCTAssertEqual(longItem.preview.count, 60,
            "Long preview should be exactly 60 characters (57 + '...')")
    }
}
#endif
