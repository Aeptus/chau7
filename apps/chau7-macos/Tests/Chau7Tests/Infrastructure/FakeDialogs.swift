import Foundation
@testable import Chau7

/// Scripted `Dialogs` for unit tests — return predetermined decisions
/// instead of trying to spin AppKit's modal loops headlessly. Tests can
/// also inspect what was asked of the dialogs (call counts and the most
/// recent default name passed to Save As).
final class FakeDialogs: Dialogs {
    var nextCloseDecision: CloseEditorDecision = .cancel
    var nextSavePanelResult: String? = nil

    private(set) var confirmCloseCallCount = 0
    private(set) var runSaveAsCallCount = 0
    private(set) var lastSaveAsDefaultName: String?

    func confirmCloseDirtyEditor() -> CloseEditorDecision {
        confirmCloseCallCount += 1
        return nextCloseDecision
    }

    func runSaveAsPanel(defaultName: String) -> String? {
        runSaveAsCallCount += 1
        lastSaveAsDefaultName = defaultName
        return nextSavePanelResult
    }
}
