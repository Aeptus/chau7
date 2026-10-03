import AppKit
import Chau7Core

/// All competing local/remote decisions and sheet lifetime belong to main.
@MainActor
final class MCPCommandApprovalPresentation {
    private let alert: NSAlert
    private let completion: (MCPApprovalResult) -> Void
    private(set) var isResolved = false

    init(alert: NSAlert, completion: @escaping (MCPApprovalResult) -> Void) {
        self.alert = alert
        self.completion = completion
    }

    func present(in window: NSWindow?) -> Bool {
        guard let window, window.attachedSheet == nil else {
            resolve(.denied)
            return false
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            let result: MCPApprovalResult
            switch response {
            case .alertSecondButtonReturn: result = .allowedOnce
            case .alertThirdButtonReturn: result = .alwaysAllow
            default: result = .denied
            }
            self?.resolve(result)
        }
        return true
    }

    func resolve(_ result: MCPApprovalResult) {
        guard !isResolved else { return }
        isResolved = true
        if let parent = alert.window.sheetParent {
            parent.endSheet(alert.window)
        }
        alert.window.orderOut(nil)
        completion(result)
    }
}
