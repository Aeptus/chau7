import Foundation

public enum OutputPatternMatcher {
    public struct Candidate: Equatable, Sendable {
        public let pattern: String
        public let appName: String

        public init(pattern: String, appName: String) {
            self.pattern = pattern
            self.appName = appName
        }
    }

    public static func firstMatch(in haystack: String, patterns: [Candidate]) -> Candidate? {
        let patternStrings = patterns.map(\.pattern)

        if let index = RustPatternMatcher.outputPatterns.firstMatchIndex(
            haystack: haystack,
            patterns: patternStrings
        ),
            index < patterns.count {
            return patterns[index]
        }

        for candidate in patterns where haystack.contains(candidate.pattern) {
            return candidate
        }
        return nil
    }
}
