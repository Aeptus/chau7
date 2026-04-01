import AppKit
import SwiftUI

/// Singleton window controller for the bug report dialog.
///
/// Follows the `DebugConsoleController` pattern: `static let shared`,
/// weak references to app model, fresh snapshot on each `show()`.
final class BugReportWindowController: NSObject, NSWindowDelegate {
    static let shared = BugReportWindowController()
    override private init() {
        super.init()
    }

    private var window: NSWindow?
    private weak var appModel: AppModel?
    private weak var overlayModel: OverlayTabsModel?

    func configure(appModel: AppModel, overlayModel: OverlayTabsModel) {
        self.appModel = appModel
        self.overlayModel = overlayModel
    }

    func show() {
        guard let appModel, let overlayModel else {
            Log.warn("BugReportWindowController: not configured, falling back to browser")
            // Fallback: open prefilled GitHub issue in browser
            if let url = BugReporter.shared.prefilledIssueURL() {
                NSWorkspace.shared.open(url)
            }
            return
        }

        // Always create a fresh window with a new snapshot
        let snapshot = StateSnapshot.capture(from: appModel, overlayModel: overlayModel)
        let currentTabID = overlayModel.selectedTabID

        let draft = BugReportDraft(
            snapshot: snapshot,
            currentTabID: currentTabID,
            overlayModel: overlayModel
        )

        let view = BugReportDialogView(draft: draft) { [weak self] in
            self?.window?.orderOut(nil)
            self?.window = nil
        }

        let hostingView = NSHostingView(rootView: view)

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = L("bugReport.windowTitle", "Report an Issue — Chau7")
        newWindow.contentView = hostingView
        newWindow.center()
        newWindow.isReleasedWhenClosed = false
        newWindow.minSize = NSSize(width: 540, height: 520)
        newWindow.delegate = self

        // Close previous window if any
        window?.orderOut(nil)
        window = newWindow

        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
