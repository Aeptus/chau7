import AppKit

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }

    /// Whether we're currently in fullscreen
    private(set) var isInFullscreen = false

    override func awakeFromNib() {
        super.awakeFromNib()
        setupFullscreenBehavior()
    }

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        setupFullscreenBehavior()
    }

    override func orderOut(_ sender: Any?) {
        Log
            .info(
                "OverlayWindow orderOut: windowNumber=\(windowNumber) frame=\(frame) content=\(contentLayoutRect) visible=\(isVisible) key=\(isKeyWindow) main=\(isMainWindow) mini=\(isMiniaturized) title='\(title)'"
            )
        super.orderOut(sender)
    }

    override func orderFront(_ sender: Any?) {
        Log.info("OverlayWindow orderFront: windowNumber=\(windowNumber) frame=\(frame) content=\(contentLayoutRect) title='\(title)'")
        super.orderFront(sender)
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        Log.info("OverlayWindow makeKeyAndOrderFront: windowNumber=\(windowNumber) frame=\(frame) visible=\(isVisible) onActiveSpace=\(isOnActiveSpace)")
        super.makeKeyAndOrderFront(sender)
    }

    override func close() {
        Log.info("OverlayWindow close: windowNumber=\(windowNumber) frame=\(frame) visible=\(isVisible) title='\(title)'")
        super.close()
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

    // MARK: - Key Equivalents

    /// Intercept ⌘; before the menu system gets it.
    ///
    /// macOS auto-injects "Edit > Show Spelling and Grammar" (⌘;) when an
    /// NSTextInputClient is first responder.  The default performKeyEquivalent
    /// dispatch walks the responder chain → menu bar and fires that system
    /// action *in addition to* the local event monitor that calls
    /// toggleSnippets().  By consuming ⌘; here, only toggleSnippets() fires
    /// (via the local monitor, which runs after performKeyEquivalent returns
    /// false — but we return true, so the monitor won't see it either).
    /// We therefore call toggleSnippets() directly.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        if flags == .command,
           event.charactersIgnoringModifiers?.lowercased() == ";" {
            // Dispatch to the AppDelegate which owns the overlay model
            if let appDelegate = NSApp.delegate as? AppDelegate {
                appDelegate.toggleSnippets()
            }
            return true // consumed — don't let menu system see it
        }
        return super.performKeyEquivalent(with: event)
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
