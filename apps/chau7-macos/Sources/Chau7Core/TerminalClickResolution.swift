import Foundation

/// Pure decisions shared by terminal URL and file-path click handling.
public enum TerminalClickResolution {
    public enum RepositoryFallback: Equatable, Sendable {
        case noMatch
        case unique(String)
        case ambiguous([String])
    }

    /// Selects a repository fallback without ever guessing between duplicates.
    public static func repositoryFallback(from matches: [String]) -> RepositoryFallback {
        let uniqueMatches = Array(Set(matches)).sorted()
        switch uniqueMatches.count {
        case 0:
            return .noMatch
        case 1:
            return .unique(uniqueMatches[0])
        default:
            return .ambiguous(uniqueMatches)
        }
    }

    /// Removes sentence punctuation from a detected URL while retaining balanced
    /// closing parentheses that are part of the URL itself.
    public static func trimmedURLToken(_ token: String) -> String {
        var result = token
        let trailingProse: Set<Character> = [".", ",", ";", ":", "!", "?"]

        while let last = result.last, trailingProse.contains(last) {
            result.removeLast()
        }

        let openingCount = result.reduce(into: 0) { count, character in
            if character == "(" { count += 1 }
        }
        var closingCount = result.reduce(into: 0) { count, character in
            if character == ")" { count += 1 }
        }

        while result.last == ")", closingCount > openingCount {
            result.removeLast()
            closingCount -= 1
        }

        return result
    }
}
