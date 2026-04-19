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
        // Only the selected (interactive) tab gets event-driven polling.
        // Background tabs drain PTY via the shared BackgroundTerminalDrainService.
        return context.isInteractive ? .eventDrain : .backgroundDrain
    }
}
