import Foundation

public enum MagiTerminalText {
    public static func normalizedInline(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public static func wrapped(_ value: String, width: Int) -> [String] {
        let width = max(1, width)
        let words = normalizedInline(value).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }

        var lines: [String] = []
        var current = ""

        for word in words {
            for chunk in chunks(word, width: width) {
                if current.isEmpty {
                    current = chunk
                } else if current.count + 1 + chunk.count <= width {
                    current += " \(chunk)"
                } else {
                    lines.append(current)
                    current = chunk
                }
            }
        }

        if !current.isEmpty {
            lines.append(current)
        }
        return lines
    }

    private static func chunks(_ value: String, width: Int) -> [String] {
        guard value.count > width else { return [value] }

        var result: [String] = []
        var start = value.startIndex
        while start < value.endIndex {
            let end = value.index(start, offsetBy: width, limitedBy: value.endIndex) ?? value.endIndex
            result.append(String(value[start ..< end]))
            start = end
        }
        return result
    }
}
