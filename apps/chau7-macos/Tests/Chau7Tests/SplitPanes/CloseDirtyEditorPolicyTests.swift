import XCTest
@testable import Chau7
@testable import Chau7Core

/// Covers the close-time save policy `closePane` enforces:
///
/// - Auto-save-enabled editors (session notes, plan.md) flush silently — these
///   files were continuously saving anyway, so close-time silent flush matches
///   the user's existing intent and avoids a surprise dialog. The behaviour is
///   exercised end-to-end in `AttachedSessionNoteTests`.
/// - Non-auto-save editors prompt to save/discard/cancel. The discard path is
///   tested here via the public `discardPendingChanges` helper; the dialog
///   itself is driven by `NSAlert.runModal()`, which we can't headlessly
///   exercise without injecting an alert host.
@MainActor
final class CloseDirtyEditorPolicyTests: XCTestCase {

    func testDiscardPendingChangesRevertsToDiskContent() throws {
        let tmpPath = NSTemporaryDirectory() + "chau7_discard_\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }
        try "persisted\n".write(toFile: tmpPath, atomically: true, encoding: .utf8)

        let model = TextEditorModel()
        model.loadFile(at: tmpPath)
        waitUntilLoaded(model, expecting: "persisted\n")

        model.updateContent("dirty edits\n")
        XCTAssertTrue(model.isDirty)

        model.discardPendingChanges()
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(model.content, "persisted\n")

        let onDisk = try String(contentsOfFile: tmpPath, encoding: .utf8)
        XCTAssertEqual(onDisk, "persisted\n", "discard must not write to disk")
    }

    func testDiscardPendingChangesOnUntitledClearsDirtyFlagOnly() {
        let model = TextEditorModel()
        model.updateContent("never saved\n")
        XCTAssertTrue(model.isDirty)
        XCTAssertNil(model.filePath)

        model.discardPendingChanges()
        XCTAssertFalse(model.isDirty)
        // No on-disk version exists, so the in-memory content is left as-is —
        // there is nothing to revert *to*. The pane is about to drop the
        // editor anyway, so the content goes with it.
        XCTAssertEqual(model.content, "never saved\n")
    }

    func testDiscardPendingChangesCancelsScheduledAutoSave() throws {
        let tmpPath = NSTemporaryDirectory() + "chau7_discard_autosave_\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }
        try "persisted\n".write(toFile: tmpPath, atomically: true, encoding: .utf8)

        let model = TextEditorModel()
        model.loadFile(at: tmpPath)
        waitUntilLoaded(model, expecting: "persisted\n")

        // Force auto-save on so the debounced work item gets scheduled.
        model.isAutoSaveEnabled = true
        model.updateContent("about to be discarded\n")
        XCTAssertTrue(model.isDirty)

        model.discardPendingChanges()
        XCTAssertFalse(model.isDirty)

        // Spin the run loop past the 2.5s debounce window; the work item is
        // cancelled, so the discarded edit must not land on disk.
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let onDisk = try String(contentsOfFile: tmpPath, encoding: .utf8)
        XCTAssertEqual(onDisk, "persisted\n")
    }

    private func waitUntilLoaded(
        _ model: TextEditorModel,
        expecting content: String,
        timeout: TimeInterval = 2.0
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !model.isLoading, model.content == content { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(model.content, content, "file did not finish loading in time")
    }
}
