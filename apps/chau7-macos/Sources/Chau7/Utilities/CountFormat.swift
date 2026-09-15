import Foundation

/// Single source for abbreviating a count as e.g. "1.2K" / "3.4M". The per-view
/// copies disagreed on threshold (`>=` vs `>`), suffix casing (`k` vs `K`) and
/// precision, so the same value rendered differently across screens.
enum CountFormat {
    static func abbreviated(_ count: Int) -> String {
        let n = Double(count)
        if count >= 1_000_000 { return "\(formatScaled(n / 1_000_000))M" }
        if count >= 1000 { return "\(formatScaled(n / 1000))K" }
        return LocalizedFormatters.formatInteger(count)
    }

    private static func formatScaled(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = FeatureSettings.shared.regionalNumberFormat.locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value)
    }
}
