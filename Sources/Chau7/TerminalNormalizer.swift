import Foundation

enum TerminalNormalizer {
    // MARK: - Pre-compiled Regex (Memory Optimization)
    // Compiled once at startup instead of on every call

    private static let ansiPattern: NSRegularExpression = {
        try! NSRegularExpression(pattern: "\\u001B\\[[0-9;?]*[ -/]*[@-~]")
    }()

    static func normalize(_ input: String) -> String {
        var output = applyBackspaces(input)
        output = stripAnsi(output)
        output = stripControlChars(output)
        return output
    }

    static func applyBackspacesOnly(_ input: String) -> String {
        applyBackspaces(input)
    }

    private static func applyBackspaces(_ input: String) -> String {
        var result: [Character] = []
        result.reserveCapacity(input.count)

        for ch in input {
            if ch == "\u{08}" || ch == "\u{7f}" {
                if !result.isEmpty {
                    result.removeLast()
                }
            } else {
                result.append(ch)
            }
        }

        return String(result)
    }

    private static func stripAnsi(_ input: String) -> String {
        let range = NSRange(input.startIndex..., in: input)
        return ansiPattern.stringByReplacingMatches(in: input, range: range, withTemplate: "")
    }

    private static func stripControlChars(_ input: String) -> String {
        // Use reserveCapacity for better memory allocation
        var result = String()
        result.reserveCapacity(input.count)

        for scalar in input.unicodeScalars {
            if scalar == "\t" || scalar.value >= 0x20 {
                result.unicodeScalars.append(scalar)
            }
        }

        return result
    }
}
