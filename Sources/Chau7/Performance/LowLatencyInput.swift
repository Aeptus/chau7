// MARK: - Low-Latency Input Handler
// Uses IOKit HID for direct keyboard access, bypassing NSEvent queue
// to achieve ~0.5-2ms lower input latency.

import Foundation
import IOKit
import IOKit.hid
import Carbon.HIToolbox

/// Low-latency keyboard input handler using IOKit HID.
/// Bypasses the NSEvent queue for reduced latency on keyboard input.
public final class LowLatencyInputHandler {

    /// Callback for key events
    public typealias KeyCallback = (KeyEvent) -> Void

    /// Represents a keyboard event
    public struct KeyEvent {
        public let keyCode: UInt32
        public let isPressed: Bool
        public let timestamp: CFAbsoluteTime
        public let modifiers: ModifierFlags

        /// Converts to character if it's a printable key
        public var character: Character? {
            KeyCodeMap.character(for: keyCode, modifiers: modifiers)
        }
    }

    /// Modifier flags for key events
    public struct ModifierFlags: OptionSet {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        public static let shift = ModifierFlags(rawValue: 1 << 0)
        public static let control = ModifierFlags(rawValue: 1 << 1)
        public static let option = ModifierFlags(rawValue: 1 << 2)
        public static let command = ModifierFlags(rawValue: 1 << 3)
        public static let capsLock = ModifierFlags(rawValue: 1 << 4)
        public static let function = ModifierFlags(rawValue: 1 << 5)
    }

    private var manager: IOHIDManager?
    private var keyCallback: KeyCallback?
    private var currentModifiers: ModifierFlags = []
    private let callbackQueue: DispatchQueue

    // Statistics
    private var eventCount: UInt64 = 0
    private var lastEventTime: CFAbsoluteTime = 0

    public init(callbackQueue: DispatchQueue = .main) {
        self.callbackQueue = callbackQueue
    }

    deinit {
        stop()
    }

    // MARK: - Public API

    /// Starts listening for keyboard events.
    /// - Parameter callback: Called for each key event
    /// - Returns: True if started successfully
    @discardableResult
    public func start(callback: @escaping KeyCallback) -> Bool {
        guard manager == nil else { return true }

        self.keyCallback = callback

        // Create HID Manager
        let hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        // Match keyboards only
        let matching: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Keyboard
        ]
        IOHIDManagerSetDeviceMatching(hidManager, matching as CFDictionary)

        // Set up callbacks
        let context = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterInputValueCallback(hidManager, { context, result, sender, value in
            guard let context = context else { return }
            let handler = Unmanaged<LowLatencyInputHandler>.fromOpaque(context).takeUnretainedValue()
            handler.handleHIDValue(value)
        }, context)

        // Schedule with run loop
        IOHIDManagerScheduleWithRunLoop(hidManager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        // Open the manager
        let result = IOHIDManagerOpen(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            Log.error("LowLatencyInput: Failed to open IOHIDManager: \(result)")
            return false
        }

        self.manager = hidManager
        Log.info("LowLatencyInput: Started HID keyboard monitoring")
        return true
    }

    /// Stops listening for keyboard events.
    public func stop() {
        guard let hidManager = manager else { return }

        IOHIDManagerUnscheduleFromRunLoop(hidManager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))

        manager = nil
        keyCallback = nil
        Log.info("LowLatencyInput: Stopped HID keyboard monitoring")
    }

    /// Whether the handler is currently active.
    public var isRunning: Bool { manager != nil }

    /// Number of events processed.
    public var totalEvents: UInt64 { eventCount }

    // MARK: - HID Callback

    private func handleHIDValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let intValue = IOHIDValueGetIntegerValue(value)
        let timestamp = CFAbsoluteTimeGetCurrent()

        // Only handle keyboard events
        guard usagePage == kHIDPage_KeyboardOrKeypad else { return }

        // Update modifier state
        updateModifiers(usage: usage, pressed: intValue != 0)

        // Skip modifier-only events if desired
        let isModifier = isModifierKey(usage)

        eventCount += 1
        lastEventTime = timestamp

        let event = KeyEvent(
            keyCode: UInt32(usage),
            isPressed: intValue != 0,
            timestamp: timestamp,
            modifiers: currentModifiers
        )

        // Dispatch callback
        if let callback = keyCallback {
            if callbackQueue == .main && Thread.isMainThread {
                callback(event)
            } else {
                callbackQueue.async {
                    callback(event)
                }
            }
        }
    }

    private func updateModifiers(usage: UInt32, pressed: Bool) {
        let modifier: ModifierFlags?

        switch Int(usage) {
        case kHIDUsage_KeyboardLeftShift, kHIDUsage_KeyboardRightShift:
            modifier = .shift
        case kHIDUsage_KeyboardLeftControl, kHIDUsage_KeyboardRightControl:
            modifier = .control
        case kHIDUsage_KeyboardLeftAlt, kHIDUsage_KeyboardRightAlt:
            modifier = .option
        case kHIDUsage_KeyboardLeftGUI, kHIDUsage_KeyboardRightGUI:
            modifier = .command
        case kHIDUsage_KeyboardCapsLock:
            modifier = .capsLock
        default:
            modifier = nil
        }

        if let mod = modifier {
            if pressed {
                currentModifiers.insert(mod)
            } else {
                currentModifiers.remove(mod)
            }
        }
    }

    private func isModifierKey(_ usage: UInt32) -> Bool {
        switch Int(usage) {
        case kHIDUsage_KeyboardLeftShift, kHIDUsage_KeyboardRightShift,
             kHIDUsage_KeyboardLeftControl, kHIDUsage_KeyboardRightControl,
             kHIDUsage_KeyboardLeftAlt, kHIDUsage_KeyboardRightAlt,
             kHIDUsage_KeyboardLeftGUI, kHIDUsage_KeyboardRightGUI,
             kHIDUsage_KeyboardCapsLock:
            return true
        default:
            return false
        }
    }
}

// MARK: - Key Code Mapping

private enum KeyCodeMap {
    // Basic ASCII mapping from HID usage to character
    static func character(for usage: UInt32, modifiers: LowLatencyInputHandler.ModifierFlags) -> Character? {
        let shift = modifiers.contains(.shift) || modifiers.contains(.capsLock)

        // Letters (a-z)
        if usage >= 0x04 && usage <= 0x1D {
            let base = Int(usage) - 0x04
            let char = Character(UnicodeScalar(base + (shift ? 65 : 97))!)
            return char
        }

        // Numbers and symbols
        switch Int(usage) {
        case 0x1E: return shift ? "!" : "1"
        case 0x1F: return shift ? "@" : "2"
        case 0x20: return shift ? "#" : "3"
        case 0x21: return shift ? "$" : "4"
        case 0x22: return shift ? "%" : "5"
        case 0x23: return shift ? "^" : "6"
        case 0x24: return shift ? "&" : "7"
        case 0x25: return shift ? "*" : "8"
        case 0x26: return shift ? "(" : "9"
        case 0x27: return shift ? ")" : "0"
        case 0x28: return "\r"  // Return
        case 0x29: return "\u{1B}"  // Escape
        case 0x2A: return "\u{7F}"  // Backspace (DEL)
        case 0x2B: return "\t"  // Tab
        case 0x2C: return " "   // Space
        case 0x2D: return shift ? "_" : "-"
        case 0x2E: return shift ? "+" : "="
        case 0x2F: return shift ? "{" : "["
        case 0x30: return shift ? "}" : "]"
        case 0x31: return shift ? "|" : "\\"
        case 0x33: return shift ? ":" : ";"
        case 0x34: return shift ? "\"" : "'"
        case 0x35: return shift ? "~" : "`"
        case 0x36: return shift ? "<" : ","
        case 0x37: return shift ? ">" : "."
        case 0x38: return shift ? "?" : "/"
        default: return nil
        }
    }
}

// MARK: - High-Resolution Timer

/// High-resolution timer for precise latency measurements.
public struct HighResolutionTimer {
    private static var timebaseInfo: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Returns current time in nanoseconds.
    public static func nowNanoseconds() -> UInt64 {
        let ticks = mach_absolute_time()
        return ticks * UInt64(timebaseInfo.numer) / UInt64(timebaseInfo.denom)
    }

    /// Returns current time in microseconds.
    public static func nowMicroseconds() -> UInt64 {
        nowNanoseconds() / 1000
    }

    /// Returns current time in milliseconds.
    public static func nowMilliseconds() -> Double {
        Double(nowNanoseconds()) / 1_000_000
    }

    /// Measures execution time of a closure in nanoseconds.
    public static func measure<T>(_ block: () throws -> T) rethrows -> (result: T, nanoseconds: UInt64) {
        let start = nowNanoseconds()
        let result = try block()
        let end = nowNanoseconds()
        return (result, end - start)
    }
}
