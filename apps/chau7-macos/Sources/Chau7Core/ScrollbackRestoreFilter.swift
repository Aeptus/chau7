import Foundation

public enum ScrollbackRestoreFilter {
    public static let maxPersistedScrollbackBytes = 500_000

    public static func captureScrollback(
        maxLines: Int,
        styledData: () -> Data?,
        fallbackData: () -> Data?
    ) -> String? {
        guard maxLines > 0 else {
            return nil
        }

        let styled = styledData()
        let data = styled?.isEmpty == false ? styled : fallbackData()
        guard let data, !data.isEmpty else {
            return nil
        }

        let text = String(decoding: data, as: UTF8.self)
        let containsANSI = text.contains("\u{1b}")
        var lines = text.components(separatedBy: "\n").map {
            containsANSI ? $0 : $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }

        lines = lines.filter { !Self.isRestoreArtifactLine(Self.visibleTextForRestoreFiltering($0)) }

        while let last = lines.last,
              Self.visibleTextForRestoreFiltering(last).isEmpty {
            lines.removeLast()
        }

        if lines.isEmpty {
            return nil
        }

        if lines.count > maxLines {
            lines = Array(lines.suffix(maxLines))
        }

        var restored = lines.joined(separator: "\n")
        if Self.visibleTextForRestoreFiltering(restored).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }

        if restored.utf8.count > Self.maxPersistedScrollbackBytes {
            guard let cappedLines = Self.scrollbackLinesWithinByteLimit(
                lines,
                maxBytes: Self.maxPersistedScrollbackBytes
            ) else {
                return nil
            }
            restored = cappedLines.joined(separator: "\n")
        }

        return restored
    }

    public static func scrollbackLinesWithinByteLimit(_ lines: [String], maxBytes: Int) -> [String]? {
        guard maxBytes > 0 else { return nil }
        var capped = lines
        var joined = capped.joined(separator: "\n")
        while joined.utf8.count > maxBytes {
            guard capped.count > 1 else {
                return nil
            }
            capped = Array(capped.suffix(max(1, capped.count / 2)))
            joined = capped.joined(separator: "\n")
        }
        return capped
    }

    public static func stripRestoreArtifacts(from content: String) -> String {
        content.components(separatedBy: "\n")
            .filter { !isRestoreArtifactLine(visibleTextForRestoreFiltering($0)) }
            .joined(separator: "\n")
    }

    static func isRestoreArtifactLine(_ line: String) -> Bool {
        let stripped = line.trimmingCharacters(in: .whitespaces)
        if stripped.contains("stty -echo"), stripped.contains("stty echo") { return true }
        if stripped.contains(" cd '"), stripped.hasSuffix("&& clear") { return true }
        if stripped.contains("%  cd '/"), stripped.hasSuffix("'") { return true }
        if stripped.contains("stty -echo; cd '"), stripped.contains("; stty echo") { return true }
        return false
    }

    private static func visibleTextForRestoreFiltering(_ text: String) -> String {
        guard EscapeSequenceSanitizer.containsEscapeSequences(text) else { return text }
        return stripEscapeSequencesPreservingWhitespace(text)
    }

    private static func stripEscapeSequencesPreservingWhitespace(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var result = String.UnicodeScalarView()
        result.reserveCapacity(scalars.count)

        var index = 0
        while index < scalars.count {
            let value = scalars[index].value
            guard value == 0x1B else {
                appendVisibleScalar(scalars[index], to: &result)
                index += 1
                continue
            }

            guard index + 1 < scalars.count else {
                break
            }

            let introducer = scalars[index + 1].value
            if introducer == 0x5B {
                index = indexAfterCSI(startingAt: index + 2, in: scalars)
            } else if introducer == 0x5D {
                index = indexAfterOSC(startingAt: index + 2, in: scalars)
            } else {
                index += 2
            }
        }

        return String(result)
    }

    private static func appendVisibleScalar(_ scalar: Unicode.Scalar, to result: inout String.UnicodeScalarView) {
        if scalar.value == 0x0A || scalar.value == 0x0D || scalar.value == 0x09 {
            result.append(scalar)
        } else if scalar.value >= 0x20, scalar.value != 0x7F {
            result.append(scalar)
        }
    }

    private static func indexAfterCSI(startingAt start: Int, in scalars: [Unicode.Scalar]) -> Int {
        var index = start
        while index < scalars.count {
            let value = scalars[index].value
            index += 1
            if value >= 0x40, value <= 0x7E {
                break
            }
        }
        return index
    }

    private static func indexAfterOSC(startingAt start: Int, in scalars: [Unicode.Scalar]) -> Int {
        var index = start
        while index < scalars.count {
            let value = scalars[index].value
            if value == 0x07 {
                return index + 1
            }
            if value == 0x1B,
               index + 1 < scalars.count,
               scalars[index + 1].value == 0x5C {
                return index + 2
            }
            index += 1
        }
        return index
    }
}
