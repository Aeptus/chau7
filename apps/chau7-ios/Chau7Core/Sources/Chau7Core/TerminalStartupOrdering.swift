/// Preserves the startup invariant for restored terminal content.
///
/// ANSI named colors are resolved through the terminal palette. The palette
/// must therefore be installed before persisted output is replayed through
/// the VTE parser; otherwise the first restored grid can be materialized with
/// fallback colors and later persisted in that degraded form.
public enum TerminalStartupOrdering {
    public static func applyPaletteThenReplay(
        initialOutput: String?,
        applyPalette: () -> Void,
        replay: (String) -> Void
    ) {
        applyPalette()
        if let initialOutput, !initialOutput.isEmpty {
            replay(initialOutput)
        }
    }
}
