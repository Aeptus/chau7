import Foundation

public enum TabStateBackupNamespace {
    public static let productionBundleIdentifier = "com.chau7.app"
    public static let productionDirectoryName = "TabStateBackups"

    public static func directoryName(bundleIdentifier: String?) -> String {
        let normalized = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard normalized == productionBundleIdentifier else {
            return "\(productionDirectoryName)-\(safeSuffix(for: normalized))"
        }
        return productionDirectoryName
    }

    private static func safeSuffix(for bundleIdentifier: String) -> String {
        let trimmed = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "unidentified-bundle" }

        var result = ""
        var previousWasSeparator = false
        for scalar in trimmed.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "_" {
                result.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                result.append("-")
                previousWasSeparator = true
            }
        }

        let sanitized = result.trimmingCharacters(in: CharacterSet(charactersIn: "-. _"))
        return sanitized.isEmpty ? "unidentified-bundle" : sanitized
    }
}
