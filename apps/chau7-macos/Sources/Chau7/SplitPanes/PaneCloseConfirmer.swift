import Foundation
import Chau7Core

/// Hosts the close-time save/discard/cancel decision for a dirty text editor
/// pane. Extracted from `SplitPaneController` so the dialog plumbing has its
/// own type with a single responsibility and a unit-testable surface.
///
/// The controller used to inline both the `Dialogs.confirmCloseDirtyEditor`
/// branching and the Save-As-on-untitled fallback. That mixed UI policy
/// with tree-shape responsibilities and made the close decision invisible
/// to tests except through the controller. With this struct, callers do
/// `confirmer.confirmCloseDirty(editor)` and follow the returned decision.
struct PaneCloseConfirmer {
    let dialogs: Dialogs

    /// What the caller should do after consulting the user.
    enum Decision: Equatable {
        /// Close the pane — either the user saved, or they explicitly
        /// chose "Don't Save" (and pending edits have been discarded).
        case proceed
        /// Keep the pane open — user cancelled the prompt, or chose
        /// Save but the Save-As panel was dismissed without picking a path.
        case abort
    }

    /// Runs the close dialog and applies the user's choice to the editor.
    ///
    /// The Save branch tries, in order:
    ///   1. `editor.save()` if a file path is set.
    ///   2. `editor.saveUntitledIfPossible()` — the attached-session-note
    ///      fast path used by `.chau7/sessions/<tab>/note.md`.
    ///   3. The Save As panel, falling back to `editor.saveAs(...)` with
    ///      whatever path the user picks.
    /// Any of those returning failure escalates to `.abort`.
    ///
    /// The Don't-Save branch calls `editor.discardPendingChanges()` so the
    /// debounced autosave can't resurrect the discarded edits after the
    /// pane is dropped from the tree.
    func confirmCloseDirty(_ editor: TextEditorModel) -> Decision {
        switch dialogs.confirmCloseDirtyEditor() {
        case .save:
            if editor.filePath != nil {
                return editor.save() ? .proceed : .abort
            }
            if editor.saveUntitledIfPossible() {
                return .proceed
            }
            return runSaveAsPanel(for: editor)
        case .dontSave:
            editor.discardPendingChanges()
            return .proceed
        case .cancel:
            return .abort
        }
    }

    private func runSaveAsPanel(for editor: TextEditorModel) -> Decision {
        let defaultName = L("editor.defaultFilename", "untitled.txt")
        guard let chosenPath = dialogs.runSaveAsPanel(defaultName: defaultName) else {
            return .abort
        }
        return editor.saveAs(to: chosenPath) ? .proceed : .abort
    }
}
