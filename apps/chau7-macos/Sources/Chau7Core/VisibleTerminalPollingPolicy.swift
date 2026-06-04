public enum VisibleTerminalPollingMode: String, Equatable {
    /// Event-driven drain: a background thread blocks in `rust.poll(timeout:)`
    /// and dispatches to main on data arrival. Zero CPU when idle.
    case eventDrain
    /// Shared background timer drains PTY at 1s intervals (non-selected tabs).
    case backgroundDrain
}

public struct VisibleTerminalPollingContext: Equatable {
    public var isTerminalStarted: Bool
    public var notifyUpdateChanges: Bool
    public var isShellBootstrapPending: Bool
    public var allowsLivePresentation: Bool
    public var isHidden: Bool
    public var hasVisibleWindow: Bool
    public var isWindowMiniaturized: Bool
    public var isInteractive: Bool

    public init(
        isTerminalStarted: Bool,
        notifyUpdateChanges: Bool,
        isShellBootstrapPending: Bool,
        allowsLivePresentation: Bool,
        isHidden: Bool,
        hasVisibleWindow: Bool,
        isWindowMiniaturized: Bool,
        isInteractive: Bool
    ) {
        self.isTerminalStarted = isTerminalStarted
        self.notifyUpdateChanges = notifyUpdateChanges
        self.isShellBootstrapPending = isShellBootstrapPending
        self.allowsLivePresentation = allowsLivePresentation
        self.isHidden = isHidden
        self.hasVisibleWindow = hasVisibleWindow
        self.isWindowMiniaturized = isWindowMiniaturized
        self.isInteractive = isInteractive
    }
}

public enum VisibleTerminalPollingPolicy {
    public static func mode(for context: VisibleTerminalPollingContext) -> VisibleTerminalPollingMode {
        guard context.isTerminalStarted, context.notifyUpdateChanges else {
            return .backgroundDrain
        }
        // Shell bootstrap needs active polling to detect first output quickly.
        if context.isShellBootstrapPending {
            return .eventDrain
        }
        guard context.allowsLivePresentation,
              !context.isHidden,
              context.hasVisibleWindow,
              !context.isWindowMiniaturized else {
            return .backgroundDrain
        }
        // Any visible window's selected tab (allowsLivePresentation == true)
        // gets event-driven polling. Pre-fix, this was gated on
        // `isInteractive`, which is only true for the key/main window — so
        // a window on a second screen would drop to the shared 1-second
        // background drain when the user clicked away, even though its
        // `phase` was `.active` and the user was watching streaming output
        // on it.
        //
        // EventDrain keeps the PTY responsive without a free-running render
        // timer. The drain may wake for metadata-only terminal events, so the
        // Rust/Swift poll pipeline must classify those separately and avoid
        // turning title/CWD churn into full-grid render invalidations.
        //
        // Non-selected tabs still hit `allowsLivePresentation == false`
        // (their phase is `.warm`) and stay on backgroundDrain, so the
        // fan-out is bounded by the number of visible windows, not tabs.
        return .eventDrain
    }
}
