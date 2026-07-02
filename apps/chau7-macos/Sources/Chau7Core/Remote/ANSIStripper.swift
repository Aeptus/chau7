import Foundation

/// Strips ANSI escape sequences from terminal output.
public enum ANSIStripper {
    public static func strip(_ input: String) -> String {
        var output = ""
        output.reserveCapacity(input.count)
        var iter = input.unicodeScalars.makeIterator()
        var scalar = iter.next()
        while let current = scalar {
            if current == "\u{1B}" {
                scalar = iter.next()
                if let next = scalar, next == "[" {
                    // Consume until final byte (0x40–0x7E)
                    while let ch = iter.next() {
                        if ch.value >= 0x40 && ch.value <= 0x7E {
                            scalar = iter.next()
                            break
                        }
                    }
                    continue
                }
                // Not a CSI sequence — skip the ESC but keep next char
                continue
            }
            output.unicodeScalars.append(current)
            scalar = iter.next()
        }
        return output
    }
}
