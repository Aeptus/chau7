import AppKit

/// Controller that manages fullscreen behavior for Chau7's overlay window.
///
/// Behavior:
/// - Tab bar stays ALWAYS visible (no hiding)
/// - macOS titlebar/menu bar auto-hide is handled via presentation options
///   in the window delegate method window(_:willUseFullScreenPresentationOptions:)
final class FullscreenToolbarController: NSObject {

    // MARK: - State

    /// Whether we're in fullscreen mode
    private(set) var isFullscreen: Bool = false

    /// The window being controlled
    private weak var window: NSWindow?

    // MARK: - Callbacks

    /// Called when traffic lights should be updated
    var onTrafficLightsNeedUpdate: ((Bool) -> Void)?

    // MARK: - Initialization

    override init() {
        super.init()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public API

    /// Attach this controller to a window
    func attach(to window: NSWindow) {
        self.window = window
    }

    // MARK: - Fullscreen Transitions

    func willEnterFullScreen() {
        // Nothing to do before entering
    }

    func didEnterFullScreen() {
        isFullscreen = true
        // Tab bar stays visible - macOS handles titlebar/menubar hiding
        // via the delegate method window(_:willUseFullScreenPresentationOptions:)
        onTrafficLightsNeedUpdate?(true)
    }

    func willExitFullScreen() {
        // Nothing to do before exiting
    }

    func didExitFullScreen() {
        isFullscreen = false
        onTrafficLightsNeedUpdate?(false)
    }
}
