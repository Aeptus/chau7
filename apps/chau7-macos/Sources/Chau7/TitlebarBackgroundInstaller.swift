import AppKit

enum TitlebarBackgroundInstaller {
    private static let backgroundIdentifier = NSUserInterfaceItemIdentifier("Chau7TitlebarBackground")

    static func install(for window: NSWindow) {
        guard let titlebarView = window.standardWindowButton(.closeButton)?.superview else { return }
        if titlebarView.subviews.contains(where: { $0.identifier == backgroundIdentifier }) {
            return
        }

        let backgroundView = NSVisualEffectView()
        backgroundView.identifier = backgroundIdentifier
        backgroundView.material = .hudWindow
        backgroundView.blendingMode = .withinWindow
        backgroundView.state = .active
        backgroundView.frame = titlebarView.bounds
        backgroundView.autoresizingMask = [.width, .height]

        titlebarView.addSubview(
            backgroundView,
            positioned: NSWindow.OrderingMode.below,
            relativeTo: nil
        )
    }
}
