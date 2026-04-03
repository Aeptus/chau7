import AppKit
import SwiftUI

/// Manages the singleton Data Explorer window.
final class DataExplorerWindow {
    static let shared = DataExplorerWindow()
    private var window: NSWindow?

    private init() {}

    func show() {
        if let existing = window {
            existing.contentView = NSHostingView(rootView: DataExplorerView())
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let view = DataExplorerView()
        let hostingView = NSHostingView(rootView: view)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("window.dataExplorer", "Data Explorer")
        window.contentView = hostingView
        window.minSize = NSSize(width: 600, height: 400)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)

        self.window = window
    }
}
