public enum VisibleTerminalPollingMode: String, Equatable {
    case backgroundDrain
    case displayLink
    case timer
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
        if context.isShellBootstrapPending {
            return .displayLink
        }
        guard context.allowsLivePresentation,
              !context.isHidden,
              context.hasVisibleWindow,
              !context.isWindowMiniaturized else {
            return .backgroundDrain
        }
        // Only the selected (interactive) tab gets the display link.
        // Background tabs drain PTY via backgroundDrain — no rendering,
        // no display link, no CPU cost. Same model as wezterm.
        return context.isInteractive ? .displayLink : .backgroundDrain
    }
}
