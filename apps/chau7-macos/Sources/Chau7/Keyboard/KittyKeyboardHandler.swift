import AppKit
import Chau7Core

/// Bridges macOS NSEvent key events to the Kitty keyboard protocol.
/// Intercepts key events when the protocol is active and encodes them
/// according to the current enhancement flags.
@MainActor
final class KittyKeyboardHandler {
    private var protocol_ = KittyKeyboardProtocol()

    var isActive: Bool { protocol_.flags > 0 }

    /// Handle a keyboard protocol request from the terminal (CSI sequence)
    func handleProtocolRequest(_ request: KeyboardProtocolRequest) -> [UInt8]? {
        switch request {
        case .push(let flags):
            protocol_.pushFlags(flags)
            Log.info("KittyKeyboard: push flags=\(flags)")
            return nil
        case .pop(let count):
            protocol_.popFlags(count: count)
            Log.info("KittyKeyboard: pop count=\(count), now flags=\(protocol_.flags)")
            return nil
        case .query:
            let response = protocol_.queryResponse()
            Log.trace("KittyKeyboard: query -> flags=\(protocol_.flags)")
            return response
        }
    }

    /// Encode an NSEvent key event using the Kitty protocol
    func encodeKeyEvent(_ event: NSEvent) -> [UInt8]? {
        guard isActive else { return nil }

        let kittyEvent = mapNSEventToKitty(event)
        return protocol_.encodeKeyEvent(kittyEvent)
    }

    /// Reset protocol state (e.g., when shell exits)
    func reset() {
        protocol_ = KittyKeyboardProtocol()
        Log.info("KittyKeyboard: reset")
    }

    private func mapNSEventToKitty(_ event: NSEvent) -> KittyKeyEvent {
        // Map NSEvent to KittyKeyEvent
        let keyCode = mapKeyCode(event)
        let modifiers = mapModifiers(event)
        let eventType: KittyEventType = event.type == .keyUp ? .release : .press
        let text = event.characters

        return KittyKeyEvent(
            keyCode: keyCode,
            modifiers: modifiers,
            eventType: eventType,
            text: text,
            legacyEncoding: [] // Fallback handled elsewhere
        )
    }

    private func mapKeyCode(_ event: NSEvent) -> Int {
        // Map common keys to Unicode codepoints
        if let chars = event.charactersIgnoringModifiers, let scalar = chars.unicodeScalars.first {
            return Int(scalar.value)
        }
        return Int(event.keyCode)
    }

    private func mapModifiers(_ event: NSEvent) -> KittyModifiers {
        var mods: KittyModifiers = []
        if event.modifierFlags.contains(.shift) { mods.insert(.shift) }
        if event.modifierFlags.contains(.option) { mods.insert(.alt) }
        if event.modifierFlags.contains(.control) { mods.insert(.ctrl) }
        if event.modifierFlags.contains(.command) { mods.insert(.super) }
        if event.modifierFlags.contains(.capsLock) { mods.insert(.capsLock) }
        return mods
    }
}
