import Foundation

public enum ChangedFilesBudget {
    public static let maximumCount = 1000
    public static let maximumEncodedBytes = 256 * 1024
    public static let maximumPathBytes = 8192

    public static func select(_ files: [String], status: CommandBlockChangedFilesStatus) -> (files: [String], truncated: Bool) {
        guard status != .notGitRepo else { return ([], false) }
        var selected: [String] = []
        var bytes = 2 // JSON array delimiters
        for path in files.prefix(maximumCount) {
            let cost = encodedPathBytes(path)
            guard cost <= maximumEncodedBytes - bytes else { return (selected, true) }
            selected.append(path)
            bytes += cost
        }
        return (selected, selected.count < files.count)
    }

    /// Includes JSON quotes, comma, and worst-case escaping of control bytes.
    public static func encodedPathBytes(_ path: String) -> Int {
        guard path.utf8.count <= maximumPathBytes else { return maximumEncodedBytes + 1 }
        return 3 + path.utf8.reduce(0) { result, byte in
            result + (byte < 0x20 ? 6 : (byte == 0x22 || byte == 0x5C || byte == 0x2F ? 2 : 1))
        }
    }
}
