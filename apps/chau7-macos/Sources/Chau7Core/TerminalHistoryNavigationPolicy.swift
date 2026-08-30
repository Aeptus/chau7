public enum TerminalHistoryNavigationPolicy {
    /// Chau7's command-history layer may consume arrow keys only while the
    /// shell itself owns terminal input. Prompt markers can become stale while
    /// an interactive child is running, so either TUI signal must win.
    public static func shouldInterceptArrowKey(
        isAtPrompt: Bool,
        hostsTUIApp: Bool,
        isAlternateScreenActive: Bool
    ) -> Bool {
        isAtPrompt && !hostsTUIApp && !isAlternateScreenActive
    }
}
