import Foundation

/// Single source for abbreviating a count as e.g. "1.2K" / "3.4M". The per-view
/// copies disagreed on threshold (`>=` vs `>`), suffix casing (`k` vs `K`) and
/// precision, so the same value rendered differently across screens.
enum CountFormat {
    static func abbreviated(_ count: Int) -> String {
        let n = Double(count)
        if count >= 1_000_000 { return String(format: "%.1fM", n / 1_000_000) }
        if count >= 1000 { return String(format: "%.1fK", n / 1000) }
        return "\(count)"
    }
}
