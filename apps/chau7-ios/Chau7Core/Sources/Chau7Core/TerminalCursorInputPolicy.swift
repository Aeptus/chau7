import Foundation

/// Limits click-to-position to the live input line, including its soft wraps.
public enum TerminalCursorInputPolicy {
    public static func permitsClick(
        isAtPrompt: Bool,
        hostsTUIApp: Bool,
        isOnCursorLine: Bool,
        displayOffset: UInt32
    ) -> Bool {
        displayOffset == 0 && isOnCursorLine && (isAtPrompt || hostsTUIApp)
    }

    /// Arrow keys move characters, rather than UTF-16 code units or grid cells.
    public static func characterDelta(in text: String, fromUTF16: Int, toUTF16: Int) -> Int? {
        guard fromUTF16 >= 0, toUTF16 >= 0 else { return nil }
        var utf16Offset = 0
        var characterOffset = 0
        var fromCharacter: Int?
        var toCharacter: Int?

        for character in text {
            if utf16Offset == fromUTF16 { fromCharacter = characterOffset }
            if utf16Offset == toUTF16 { toCharacter = characterOffset }
            utf16Offset += String(character).utf16.count
            characterOffset += 1
        }
        if utf16Offset == fromUTF16 { fromCharacter = characterOffset }
        if utf16Offset == toUTF16 { toCharacter = characterOffset }
        guard let fromCharacter, let toCharacter else { return nil }
        return toCharacter - fromCharacter
    }
}
