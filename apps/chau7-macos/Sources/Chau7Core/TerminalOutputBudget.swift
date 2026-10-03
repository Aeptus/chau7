import Foundation

public enum TerminalOutputBudget {
    /// UTF-8-safe tail with strict byte and line ceilings, including one enormous line.
    public static func tail(_ text: String, maximumLines: Int, maximumBytes: Int) -> String {
        guard maximumLines > 0, maximumBytes > 0 else { return "" }
        let utf8 = text.utf8
        var start = utf8.index(utf8.endIndex, offsetBy: -maximumBytes, limitedBy: utf8.startIndex) ?? utf8.startIndex
        while start != utf8.endIndex, utf8[start] & 0xC0 == 0x80 {
            utf8.formIndex(after: &start)
        }
        let bounded = String(decoding: utf8[start...], as: UTF8.self)
        return bounded.split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(maximumLines).joined(separator: "\n")
    }
}
