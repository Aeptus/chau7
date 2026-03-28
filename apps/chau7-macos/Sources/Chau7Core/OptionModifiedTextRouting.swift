import Foundation

/// Decides when an Option-modified key event should be treated as literal text
/// instead of a terminal Meta/Alt shortcut.
///
/// International keyboard layouts use Option to produce programming characters
/// like `[` and `{`. Those combinations should flow through NSTextInputContext
/// so the terminal receives the rendered character, not an ESC-prefixed fallback.
public enum OptionModifiedTextRouting {
    public static func shouldTreatAsLiteralText(
        characters: String?,
        charactersIgnoringModifiers: String?,
        hasOption: Bool,
        hasControl: Bool,
        hasCommand: Bool
    ) -> Bool {
        guard hasOption, !hasControl, !hasCommand,
              let characters,
              let baseCharacters = charactersIgnoringModifiers,
              characters.unicodeScalars.count == 1,
              baseCharacters.unicodeScalars.count == 1,
              characters != baseCharacters,
              let rendered = characters.unicodeScalars.first,
              let base = baseCharacters.unicodeScalars.first,
              rendered.isASCII,
              rendered.value >= 0x20,
              rendered.value != 0x7F else {
            return false
        }

        // Preserve traditional Alt/meta behavior for letter chords like Opt+B,
        // but allow Option-generated punctuation from non-letter base keys.
        return !base.properties.isAlphabetic
    }
}
