import Foundation

/// Shared provider bucketing for analytics surfaces.
///
/// Telemetry runs and proxy calls currently persist different raw provider
/// strings ("codex", "Claude Code", "openai", "gemini", ...). Analytics
/// should group them under stable vendor-facing keys so totals and filters
/// stay coherent across views.
public enum AnalyticsProvider {
    private static let canonicalDisplayNames: [String: String] = [
        "anthropic": "Anthropic",
        "openai": "OpenAI",
        "google": "Google",
        "github": "GitHub",
        "xai": "xAI",
        "openrouter": "OpenRouter",
        "meta": "Meta",
        "mistral": "Mistral",
        "deepseek": "DeepSeek",
        "unknown": "Unknown",
    ]

    /// Returns the stable analytics key for a raw provider string.
    ///
    /// Known tool-level providers are folded into their vendor family:
    /// - `claude` / `Claude Code` -> `anthropic`
    /// - `codex` / `chatgpt` / `openai` -> `openai`
    /// - `gemini` / `google` -> `google`
    ///
    /// Unknown values are preserved as lowercased keys so analytics can still
    /// surface and filter them.
    public static func key(for rawValue: String?) -> String? {
        guard let trimmed = normalizedTrimmed(rawValue) else { return nil }

        if let resumeKey = AIResumeParser.normalizeProviderName(trimmed) {
            switch resumeKey {
            case "claude":
                return "anthropic"
            case "codex":
                return "openai"
            default:
                return resumeKey
            }
        }

        let lowered = trimmed.lowercased()

        if lowered.contains("anthropic") || lowered.contains("claude") {
            return "anthropic"
        }
        if lowered.contains("openai") || lowered.contains("chatgpt") || lowered.contains("codex") {
            return "openai"
        }
        if lowered == "google" || lowered.contains("gemini") || lowered.contains("google ai") {
            return "google"
        }
        if lowered.contains("github") || lowered.contains("copilot") {
            return "github"
        }
        if lowered.contains("openrouter") {
            return "openrouter"
        }
        if lowered.contains("deepseek") {
            return "deepseek"
        }
        if lowered.contains("mistral") {
            return "mistral"
        }
        if lowered == "xai" || lowered.contains("grok") {
            return "xai"
        }
        if lowered.contains("meta") || lowered.contains("llama") {
            return "meta"
        }
        if lowered == "unknown" {
            return "unknown"
        }

        return lowered
    }

    public static func displayName(for rawValue: String?) -> String {
        guard let key = key(for: rawValue) else { return "Unknown" }
        if let displayName = canonicalDisplayNames[key] {
            return displayName
        }
        return prettify(key)
    }

    public static func sortKeys(_ keys: some Sequence<String>) -> [String] {
        Array(Set(keys.map { $0.lowercased() }))
            .sorted { lhs, rhs in
                let leftRank = sortRank(for: lhs)
                let rightRank = sortRank(for: rhs)
                if leftRank != rightRank {
                    return leftRank < rightRank
                }
                return displayName(for: lhs).localizedCaseInsensitiveCompare(displayName(for: rhs)) == .orderedAscending
            }
    }

    public static func matches(_ rawValue: String?, filterKey: String?) -> Bool {
        guard let normalizedFilter = normalizedTrimmed(filterKey)?.lowercased(),
              normalizedFilter != "all" else {
            return true
        }
        return key(for: rawValue) == normalizedFilter
    }

    private static func normalizedTrimmed(_ rawValue: String?) -> String? {
        guard let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func sortRank(for key: String) -> Int {
        switch key {
        case "anthropic": return 0
        case "openai": return 1
        case "google": return 2
        case "github": return 3
        case "openrouter": return 4
        case "xai": return 5
        case "meta": return 6
        case "mistral": return 7
        case "deepseek": return 8
        case "unknown": return 99
        default: return 50
        }
    }

    private static func prettify(_ key: String) -> String {
        key
            .split(separator: Character("-"))
            .map { token in
                let value = String(token)
                if value.count <= 3 {
                    return value.uppercased()
                }
                return value.prefix(1).uppercased() + value.dropFirst()
            }
            .joined(separator: " ")
    }
}
