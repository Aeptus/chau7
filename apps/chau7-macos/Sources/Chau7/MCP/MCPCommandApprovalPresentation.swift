import AppKit
import Chau7Core

/// Maps the shared one-shot sheet owner onto MCP permission decisions.
@MainActor
final class MCPCommandApprovalPresentation {
    private let presentation: ConfirmationSheetPresentation
    var isResolved: Bool {
        presentation.isResolved
    }

    init(alert: NSAlert, completion: @escaping (MCPApprovalResult) -> Void) {
        self.presentation = ConfirmationSheetPresentation(alert: alert) { response in
            switch response {
            case .alertSecondButtonReturn: completion(.allowedOnce)
            case .alertThirdButtonReturn: completion(.alwaysAllow)
            default: completion(.denied)
            }
        }
    }

    func present(in window: NSWindow?) -> Bool {
        presentation.present(in: window)
    }

    func resolve(_ result: MCPApprovalResult) {
        switch result {
        case .allowedOnce: presentation.resolve(.alertSecondButtonReturn)
        case .alwaysAllow: presentation.resolve(.alertThirdButtonReturn)
        case .denied: presentation.resolve(.abort)
        }
    }
}
