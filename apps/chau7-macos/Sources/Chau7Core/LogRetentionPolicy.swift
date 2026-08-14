import Foundation

public enum LogRetentionPolicy {
    /// Returns at most `maximumBytes`, dropping a leading partial line when
    /// the suffix starts in the middle of a record.
    public static func lineAlignedTail(of data: Data, maximumBytes: Int) -> Data {
        let limit = max(0, maximumBytes)
        guard limit > 0 else { return Data() }
        guard data.count > limit else { return data }

        let suffix = Data(data.suffix(limit))
        guard let newline = suffix.firstIndex(of: 0x0A) else { return Data() }
        return Data(suffix.suffix(from: suffix.index(after: newline)))
    }
}
