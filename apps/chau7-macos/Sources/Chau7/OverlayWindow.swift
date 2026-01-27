import AppKit

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Whether we're currently in fullscreen
    private(set) var isInFullscreen: Bool = false

    override func awakeFromNib() {
        super.awakeFromNib()
        setupFullscreenBehavior()
    }

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        setupFullscreenBehavior()
    }

    private func setupFullscreenBehavior() {
        // Allow fullscreen with managed behavior
        collectionBehavior = [.fullScreenPrimary, .managed]

        // Observe fullscreen transitions
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didEnterFullScreen),
            name: NSWindow.didEnterFullScreenNotification,
            object: self
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didExitFullScreen),
            name: NSWindow.didExitFullScreenNotification,
            object: self
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Fullscreen Handling

    @objc private func didEnterFullScreen(_ notification: Notification) {
        isInFullscreen = true
        // Miniaturize button is disabled in fullscreen (macOS doesn't allow it)
        standardWindowButton(.miniaturizeButton)?.isEnabled = false
    }

    @objc private func didExitFullScreen(_ notification: Notification) {
        isInFullscreen = false
        standardWindowButton(.miniaturizeButton)?.isEnabled = true
    }
}
