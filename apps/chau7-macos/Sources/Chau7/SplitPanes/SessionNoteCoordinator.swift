import Foundation
import Chau7Core

/// Owns the file-system surface of the tab-scoped session note attachment —
/// `.chau7/sessions/<tabID>/note.md` inside the active repo root. Extracted
/// from `SplitPaneController` so the path math, disk-existence checks, and
/// prepare-on-demand "ensure file exists" step have their own home and
/// stop bleeding into the tree-shape responsibilities.
///
/// Construction is intentionally cheap and side-effect-free; only
/// `prepareNoteFile()` actually touches the disk. Callers should construct
/// fresh instances per call — the (tabID, repoRoot) pair fully captures
/// the binding.
struct SessionNoteCoordinator {
    let tabID: UUID
    let repoRoot: String

    /// Path the attached session note will live at, regardless of whether
    /// the file already exists.
    var attachedNotePath: String {
        SessionNoteAttachmentLocator.filePath(repoRoot: repoRoot, tabID: tabID)
    }

    /// Returns the note path only when the file is already on disk. Used
    /// by restore-on-relaunch to decide whether to reopen an editor pane.
    var existingNotePath: String? {
        let path = attachedNotePath
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// Ensures the parent directory and a (possibly empty) note file exist
    /// on disk so an editor can load against a real path. Idempotent — the
    /// directory and file are only created when missing.
    @discardableResult
    func prepareNoteFile() -> String {
        let path = attachedNotePath
        let url = URL(fileURLWithPath: path)
        FileOperations.createDirectory(at: url.deletingLastPathComponent())
        if !FileManager.default.fileExists(atPath: url.path) {
            _ = FileOperations.writeString("", to: url.path)
        }
        return path
    }
}
