import SwiftUI

/// Single source for provider/backend display colors, resolving the per-view
/// drift the audit flagged — e.g. "claude" rendered orange in the agent
/// dashboard but purple in the explorers. Accepts both tool names ("claude",
/// "codex") and API provider ids ("anthropic", "openai").
enum ProviderColors {
    static func color(for provider: String) -> Color {
        switch provider.lowercased() {
        case "claude", "anthropic": return .purple
        case "codex", "openai": return .green
        case "cline": return .orange
        case "chatgpt": return .teal
        case "gemini", "google": return .blue
        default: return .secondary
        }
    }
}
