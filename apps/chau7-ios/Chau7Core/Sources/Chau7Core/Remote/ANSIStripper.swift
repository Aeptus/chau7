import Foundation

/// Strips ANSI escape sequences from terminal output.
///
/// The previous implementation only understood `ESC [` (CSI). Every other
/// escape dropped just the `ESC` byte and then let the rest of the sequence
/// print as visible text, so:
///
/// - `ESC ] 7 ; file:///Users/me/proj ESC \` (OSC 7, the cwd report that
///   zsh and fish emit on essentially every prompt) rendered as
///   `7;file:///Users/me/proj\`.
/// - `ESC ( B` (charset selection) rendered as `(B`.
/// - `ESC P … ESC \` (DCS) rendered as `Pqdata`.
/// - 8-bit C1 `CSI` (`U+009B`) rendered as `31m`.
///
/// This version consumes each introducer family to its real terminator while
/// keeping the deliberately lenient handling of *unknown* escapes: a bare
/// `ESC` in front of ordinary text must not swallow that text.
public enum ANSIStripper {
    /// CSI introducer: `ESC [` (and the 8-bit C1 form `U+009B`).
    private static let csiIntroducer: Unicode.Scalar = "["
    /// OSC introducer: `ESC ]` (and the 8-bit C1 form `U+009D`).
    private static let oscIntroducer: Unicode.Scalar = "]"
    /// String-terminated introducers: DCS, PM, APC. Always end at ST.
    private static let stringIntroducers: Set<Unicode.Scalar> = ["P", "^", "_"]
    /// Charset introducers: each takes exactly one designator byte, so
    /// `ESC ( B` is three bytes, not two.
    private static let charsetIntroducers: Set<Unicode.Scalar> = ["(", ")", "*", "+"]

    private static let escape: Unicode.Scalar = "\u{1B}"
    private static let stringTerminator: Unicode.Scalar = "\\"
    private static let bell: Unicode.Scalar = "\u{07}"
    private static let c1CSI: Unicode.Scalar = "\u{9B}"
    private static let c1OSC: Unicode.Scalar = "\u{9D}"

    public static func strip(_ input: String) -> String {
        var iterator = input.unicodeScalars.makeIterator()
        var output = String.UnicodeScalarView()
        // `input.count` is a Character count, which under-reserves for any
        // multi-byte content and forced repeated reallocation. Scalars is the
        // unit the loop actually appends.
        output.reserveCapacity(input.unicodeScalars.count)

        var pending = iterator.next()
        while let scalar = pending {
            if scalar == escape {
                pending = consumeEscape(iterator: &iterator)
                continue
            }
            if scalar == c1CSI {
                pending = consumeCSI(iterator: &iterator)
                continue
            }
            if scalar == c1OSC {
                pending = consumeString(iterator: &iterator, terminatesOnBell: true)
                continue
            }
            output.append(scalar)
            pending = iterator.next()
        }
        return String(output)
    }

    /// Consumes an escape sequence and returns the next scalar to process, or
    /// `nil` when the input ended inside the sequence.
    private static func consumeEscape(
        iterator: inout String.UnicodeScalarView.Iterator
    ) -> Unicode.Scalar? {
        guard let introducer = iterator.next() else { return nil }

        if introducer == csiIntroducer {
            return consumeCSI(iterator: &iterator)
        }
        if introducer == oscIntroducer {
            return consumeString(iterator: &iterator, terminatesOnBell: true)
        }
        if stringIntroducers.contains(introducer) {
            return consumeString(iterator: &iterator, terminatesOnBell: false)
        }
        if charsetIntroducers.contains(introducer) {
            // Drop the designator byte too, otherwise `ESC ( B` leaks `B`.
            _ = iterator.next()
            return iterator.next()
        }
        // Unknown escape: drop the `ESC` but leave the following character
        // alone. A lone `ESC` in front of ordinary text (truncated or mangled
        // output) must not swallow visible content.
        return introducer
    }

    /// CSI runs to a final byte in 0x40…0x7E.
    private static func consumeCSI(
        iterator: inout String.UnicodeScalarView.Iterator
    ) -> Unicode.Scalar? {
        while let scalar = iterator.next() {
            if scalar.value >= 0x40, scalar.value <= 0x7E {
                return iterator.next()
            }
        }
        return nil
    }

    /// OSC ends at BEL; DCS/PM/APC end at ST (`ESC \`). The backslash that
    /// completes ST is consumed too, otherwise it leaks as visible text.
    private static func consumeString(
        iterator: inout String.UnicodeScalarView.Iterator,
        terminatesOnBell: Bool
    ) -> Unicode.Scalar? {
        var sawEscape = false
        while let scalar = iterator.next() {
            if terminatesOnBell, scalar == bell {
                return iterator.next()
            }
            if sawEscape {
                if scalar == stringTerminator {
                    return iterator.next()
                }
                sawEscape = false
                continue
            }
            if scalar == escape {
                sawEscape = true
            }
        }
        return nil
    }
}
