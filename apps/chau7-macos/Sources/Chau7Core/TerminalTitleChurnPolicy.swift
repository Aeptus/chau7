import Foundation

public enum TerminalTitleChurnPolicy {
    public static func stableDisplayTitle(from rawTitle: String) -> String {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstScalar = trimmed.unicodeScalars.first else {
            return trimmed
        }

        let firstIndex = trimmed.startIndex
        let afterFirst = trimmed.index(after: firstIndex)
        let remaining = String(trimmed[afterFirst...])

        guard isSpinnerScalar(firstScalar),
              remaining.first?.isWhitespace == true else {
            return trimmed
        }

        let normalized = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? trimmed : normalized
    }

    public static func shouldDeliverTitle(_ rawTitle: String, lastDeliveredTitle: String?) -> Bool {
        stableDisplayTitle(from: rawTitle) != lastDeliveredTitle
    }

    private static func isSpinnerScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if (0x2800 ... 0x28FF).contains(value) {
            return true
        }

        switch scalar {
        case "-", "\\", "|", "/",
             "◐", "◓", "◑", "◒", "◴", "◷", "◶", "◵",
             "✳", "✴", "✶", "✷", "✸", "✹", "✺",
             "⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷":
            return true
        default:
            return false
        }
    }
}
