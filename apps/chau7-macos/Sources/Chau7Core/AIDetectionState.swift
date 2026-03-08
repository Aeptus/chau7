import Foundation

/// Pure state machine for AI tool detection in a terminal session.
///
/// Owns the detection lifecycle: scanning for patterns, detecting a tool,
/// cooldown after prompt return, re-detection locked to the same tool,
/// and restoration from persisted state.
///
/// `TerminalSessionModel` owns an instance and calls the mutation methods
/// when terminal events occur. Side effects (logging, telemetry, UI updates)
/// are handled by `TerminalSessionModel` based on the return values.
///
/// This struct lives in Chau7Core so it can be unit-tested without app dependencies.
public struct AIDetectionState: Sendable {

    /// Detection lifecycle phase.
    public enum Phase: Equatable, Sendable {
        /// No AI tool detected. Scanning output and commands for patterns.
        case scanning
        /// An AI tool is actively detected. Output scanning is paused.
        case detected
        /// After prompt return (OSC 7), within the re-detection window.
        /// Only the previously-detected tool can be re-detected from output.
        case redetecting
        /// AI metadata restored from persisted tab state. Dimmed logo in UI.
        case restored
    }

    // MARK: - Public State (read by TerminalSessionModel)

    /// The currently active AI app name (e.g. "Claude"). Nil when scanning.
    public private(set) var currentApp: String?

    /// Whether the current state came from persistence rather than live detection.
    public var isRestored: Bool { phase == .restored }

    /// The last live-detected app name. Survives phase transitions.
    /// Used to lock re-detection to the same tool after prompt return.
    public private(set) var lastDetectedApp: String?

    /// Current phase of the detection lifecycle.
    public private(set) var phase: Phase = .scanning

    // MARK: - Internal State

    /// Timestamp when detection was last set (for cooldown calculation).
    private var detectedAt: Date?
    /// Chunks processed since entering the redetecting phase.
    private var chunksSinceClearing: Int = 0
    /// Sliding buffer for cross-chunk pattern matching.
    private var slidingBuffer = Data()

    // MARK: - Constants

    /// Don't clear detection within this many seconds of the last detection event.
    private let cooldownSeconds: TimeInterval = 3.0
    /// After clearing, re-check this many output chunks before giving up.
    private let retryChunks: Int = 30
    /// Size of the sliding buffer tail kept across chunks.
    private let bufferCapacity: Int = 256

    // MARK: - Init

    public init() {}

    // MARK: - Sliding Buffer

    /// Appends `chunk` to the internal sliding buffer and returns the lowercased
    /// combined string (up to 2 KB) for the caller to run pattern matching against.
    ///
    /// When in `.detected` phase, resets the chunk counter (keeping detection alive)
    /// and returns nil to skip expensive pattern matching.
    ///
    /// Returns nil if UTF-8 decoding fails or matching should be skipped.
    public mutating func prepareHaystack(chunk: Data) -> String? {
        if phase == .detected {
            chunksSinceClearing = 0
            return nil
        }

        if phase == .redetecting {
            chunksSinceClearing += 1
            if chunksSinceClearing > retryChunks {
                // Retry window exhausted — give up re-detection
                phase = .scanning
                currentApp = nil
                detectedAt = nil
                return nil
            }
        }

        // Build sliding buffer: previous tail + current chunk (up to 2 KB)
        var combined = slidingBuffer
        combined.append(chunk.prefix(2048))
        let checkData = combined.suffix(2048)

        // Update buffer with tail of current chunk
        let tailSize = min(chunk.count, bufferCapacity)
        slidingBuffer = chunk.suffix(tailSize)

        guard let rawString = String(data: checkData, encoding: .utf8) else { return nil }
        return rawString.lowercased()
    }

    // MARK: - State Mutations

    /// Called when pattern matching completes on prepared haystack.
    /// `appName` is the matched tool name, or nil if no match.
    /// Returns true if the state changed.
    @discardableResult
    public mutating func handleOutputMatch(appName: String?) -> Bool {
        guard let appName else { return false }

        switch phase {
        case .scanning:
            return setDetected(appName)
        case .redetecting:
            // Only accept the same tool that was previously detected
            guard appName == lastDetectedApp else { return false }
            return setDetected(appName)
        case .restored:
            // Live detection overrides restoration
            return setDetected(appName)
        case .detected:
            // Already detected — shouldn't reach here (prepareHaystack returns nil)
            return false
        }
    }

    /// Called when a command line is entered that matches a known AI tool.
    /// Always overrides current state (command-line detection is high-confidence).
    /// Returns true if the state changed.
    @discardableResult
    public mutating func handleCommand(appName: String?) -> Bool {
        guard let appName else { return false }
        return setDetected(appName)
    }

    /// Called when OSC 7 / shell prompt is detected (AI tool returned to prompt).
    /// Implements cooldown: no-ops if within `cooldownSeconds` of last detection.
    /// Returns true if the state changed (cleared or entered redetecting).
    @discardableResult
    public mutating func handlePromptReturn() -> Bool {
        guard phase == .detected || phase == .restored else { return false }
        guard currentApp != nil else { return false }

        // Restored sessions stay in .restored (dimmed logo in UI).
        // Clear currentApp so output scanning can detect a new live tool,
        // but don't change the phase — isRestored should remain true.
        if phase == .restored {
            currentApp = nil
            return true
        }

        // Cooldown: don't clear too soon after detection
        if let detectedAt {
            let elapsed = Date().timeIntervalSince(detectedAt)
            if elapsed < cooldownSeconds {
                return false
            }
        }

        // Transition to redetecting (or scanning if no previous detection to lock to)
        if lastDetectedApp != nil {
            phase = .redetecting
        } else {
            phase = .scanning
        }
        currentApp = nil
        detectedAt = nil
        chunksSinceClearing = 0
        slidingBuffer.removeAll(keepingCapacity: true)
        return true
    }

    /// Called when restoring AI metadata from persisted tab state.
    /// Returns true if the state changed.
    @discardableResult
    public mutating func handleRestore(appName: String) -> Bool {
        currentApp = appName
        phase = .restored
        detectedAt = nil
        // Don't set lastDetectedApp — restored sessions shouldn't lock re-detection
        return true
    }

    /// Called when an exit/logout/quit command is detected.
    /// Immediately clears detection with no cooldown.
    /// Returns true if the state changed.
    @discardableResult
    public mutating func handleExit() -> Bool {
        guard currentApp != nil else { return false }
        currentApp = nil
        phase = .scanning
        detectedAt = nil
        chunksSinceClearing = 0
        slidingBuffer.removeAll(keepingCapacity: true)
        return true
    }

    // MARK: - Internal (test support)

    /// Creates a state in `.redetecting` phase for unit testing.
    /// Internal so tests can access via `@testable import`.
    static func makeRedetecting(lastTool: String) -> AIDetectionState {
        var state = AIDetectionState()
        state.currentApp = nil
        state.lastDetectedApp = lastTool
        state.phase = .redetecting
        state.detectedAt = nil
        state.chunksSinceClearing = 0
        return state
    }

    // MARK: - Private

    private mutating func setDetected(_ appName: String) -> Bool {
        currentApp = appName
        lastDetectedApp = appName
        phase = .detected
        detectedAt = Date()
        chunksSinceClearing = 0
        slidingBuffer.removeAll(keepingCapacity: true)
        return true
    }
}
