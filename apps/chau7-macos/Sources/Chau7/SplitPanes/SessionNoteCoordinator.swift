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
        SessionNoteFileStore.existing(repoRoot: repoRoot, tabID: tabID)
    }

    /// Prepares a note only below a still-existing repository. Missing roots,
    /// symlink escapes and failed creation report an unavailable note.
    @discardableResult
    func prepareNoteFile() -> String? {
        SessionNoteFileStore.prepare(repoRoot: repoRoot, tabID: tabID)
    }
}
