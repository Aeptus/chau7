import AppKit
import Chau7Core
import UniformTypeIdentifiers

/// Outcome of the "save changes?" prompt shown when closing a dirty editor.
enum CloseEditorDecision {
    case save
    case dontSave
    case cancel
}

/// The two modal dialogs the side-panel controller drives — the close
/// confirm and the Save As panel — routed through a protocol so tests can
/// supply a `FakeDialogs` that returns predetermined outcomes instead of
/// trying to spin AppKit modal loops headlessly.
protocol Dialogs {
    func confirmCloseDirtyEditor() -> CloseEditorDecision
    /// Returns the chosen file path, or `nil` when the user cancels.
    func runSaveAsPanel(defaultName: String) -> String?
}

/// Production impl backed by `NSAlert` / `NSSavePanel`. Localized button
/// titles match the strings the previous inline-in-controller dialogs used,
/// so this is a strict refactor, not a UX change.
struct SystemDialogs: Dialogs {
    func confirmCloseDirtyEditor() -> CloseEditorDecision {
        let alert = NSAlert()
        alert.messageText = L("alert.closeEditor.title", "Save changes?")
        alert.informativeText = L(
            "alert.closeEditor.message",
            "Your changes will be lost if you don't save them."
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("button.save", "Save"))
        alert.addButton(withTitle: L("button.dontSave", "Don't Save"))
        alert.addButton(withTitle: L("button.cancel", "Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .dontSave
        default: return .cancel
        }
    }

    func runSaveAsPanel(defaultName: String) -> String? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultName
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }
}
