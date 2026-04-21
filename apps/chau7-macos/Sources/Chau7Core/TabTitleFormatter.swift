import Foundation

public enum TabTitleFormatter {
    public static func resolvedTitle(
        customTitle: String?,
        aiDisplayAppName: String?,
        devServerName: String?,
        customTitleOnly: Bool,
        shellFallback: String = "Shell"
    ) -> String {
        let custom = trimmedNonEmpty(customTitle)
        let aiName = trimmedNonEmpty(aiDisplayAppName)

        if let custom {
            if customTitleOnly {
                return custom
            }
            if let aiName {
                if custom.range(of: aiName, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                    return custom
                }
                return "\(aiName) - \(custom)"
            }
            return custom
        }

        if let aiName {
            return aiName
        }

        if let devServerName = trimmedNonEmpty(devServerName),
           devServerName.compare("Vite", options: .caseInsensitive) == .orderedSame {
            return devServerName
        }

        return shellFallback
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
