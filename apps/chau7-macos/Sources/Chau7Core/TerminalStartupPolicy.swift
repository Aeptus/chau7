public enum TerminalStartupPolicy {
    public static func shouldStartTerminal(
        isStarted: Bool,
        containerWidth: Double,
        containerHeight: Double,
        rustViewWidth: Double,
        rustViewHeight: Double
    ) -> Bool {
        guard !isStarted else { return false }
        let containerReady = containerWidth > 0 && containerHeight > 0
        let rustViewReady = rustViewWidth > 0 && rustViewHeight > 0
        return containerReady || rustViewReady
    }
}
