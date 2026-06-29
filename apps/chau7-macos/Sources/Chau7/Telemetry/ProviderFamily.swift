import Foundation

/// Canonical AI-provider family classification, single-sourced so the telemetry
/// recorder/repair paths stop each re-deriving "lowercased contains
/// claude/anthropic/codex/openai" with subtly different sets.
///
/// The per-provider `RunContentProvider.canHandle` checks stay separate — they
/// intentionally differ (e.g. Codex also matches "gpt").
enum ProviderFamily {
    case claude
    case codex
    case other

    static func classify(_ provider: String) -> ProviderFamily {
        let p = provider.lowercased()
        if p.contains("claude") || p.contains("anthropic") { return .claude }
        if p.contains("codex") || p.contains("openai") { return .codex }
        return .other
    }
}
