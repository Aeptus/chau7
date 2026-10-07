/// Return submits only a keyboard event; clipboard content always remains editable.
public enum RemoteComposerInputPolicy {
    public static func shouldSubmit(insertedText: String, isPasting: Bool, holdToSend: Bool) -> Bool {
        !holdToSend && !isPasting && insertedText == "\n"
    }
}
