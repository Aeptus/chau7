/// Return submits only a keyboard event; clipboard content always remains editable.
public enum RemoteComposerInputPolicy {
    public static func shouldSubmit(insertedText: String, isPasting: Bool, holdToSend: Bool) -> Bool {
        !holdToSend && !isPasting && insertedText == "\n"
    }

    public enum FocusChange: Equatable, Sendable { case takeKeyboard, releaseKeyboard }

    /// What the text view must do so that it holds the keyboard exactly when the
    /// screen asked for it. `nil` when it already matches.
    public static func focusChange(requested: Bool, isFirstResponder: Bool) -> FocusChange? {
        guard requested != isFirstResponder else { return nil }
        return requested ? .takeKeyboard : .releaseKeyboard
    }
}
