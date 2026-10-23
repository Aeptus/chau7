import Foundation

public enum ProviderLatencyOutputHeuristics {
    private static let ignorableSpinnerGlyphs: Set<Character> = [
        "⠁", "⠂", "⠄", "⡀", "⢀", "⠠", "⠐", "⠈",
        "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏",
        "⢹", "⢺", "⢼", "⣸", "⣇", "⡧", "⡗", "⡏",
        "⋮", "…", "·", "•"
    ]

    public static func hasMeaningfulFirstResponseText(in data: Data) -> Bool {
        guard let raw = String(data: data, encoding: .utf8) else { return false }
        let sanitized = EscapeSequenceSanitizer.sanitize(raw)
        guard !sanitized.isEmpty else { return false }

        let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.allSatisfy({ ignorableSpinnerGlyphs.contains($0) }) {
            return false
        }

        return trimmed.unicodeScalars.contains { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.symbols.contains(scalar)
        }
    }
}
