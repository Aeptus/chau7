/// Determines whether a hardware keyboard event is eligible for delivery to
/// a terminal PTY.
///
/// AppKit can temporarily leave a window marked as key when its Space is no
/// longer active. The window also retains its first responder, so those two
/// signals alone are not sufficient to prove that the user is typing into the
/// terminal.
public enum TerminalKeyboardInputPolicy {
    public static func shouldRouteHardwareEvent(
        isApplicationActive: Bool,
        isWindowKey: Bool,
        isWindowOnActiveSpace: Bool,
        eventTargetsWindow: Bool,
        terminalOwnsFirstResponder: Bool
    ) -> Bool {
        isApplicationActive
            && isWindowKey
            && isWindowOnActiveSpace
            && eventTargetsWindow
            && terminalOwnsFirstResponder
    }
}
