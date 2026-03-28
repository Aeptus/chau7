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
    public var isRestored: Bool {
        phase == .restored
    }

    /// The last live-detected app name. Survives phase transitions.
    /// Used to lock re-detection to the same tool after prompt return.
    public private(set) var lastDetectedApp: String?

    /// Current phase of the detection lifecycle.
    public private(set) var phase: Phase = .scanning

    /// Number of times UTF-8 decoding failed in `prepareHaystack`.
    /// Callers can read this to log diagnostics (Chau7Core has no Log dependency).
    public private(set) var utf8DecodeFailures = 0

    // MARK: - Internal State

    /// Timestamp when detection was last set (for cooldown calculation).
    private var detectedAt: Date?
    /// Deadline for the re-detection retry window (time-based, not chunk-count).
    private var redetectionDeadline: Date?
    /// Sliding buffer tail for cross-chunk pattern matching (String, not Data,
    /// to avoid splitting multi-byte UTF-8 characters at chunk boundaries).
    private var slidingBufferTail = ""

    // MARK: - Constants

    /// Don't clear detection within this many seconds of the last detection event.
    private let cooldownSeconds: TimeInterval = 3.0
    /// After entering `.redetecting`, keep scanning output for this many seconds
    /// before giving up. Time-based (not chunk-count) so the window is deterministic
    /// regardless of output granularity.
    private let redetectionWindowSeconds: TimeInterval = 5.0
    /// Maximum character count of the sliding buffer tail kept across chunks.
    private let bufferTailCapacity = 256

    // MARK: - Init

    public init() {}

    // MARK: - Sliding Buffer

    /// Appends `chunk` to the internal sliding buffer and returns the lowercased
    /// combined string (up to 2 KB) for the caller to run pattern matching against.
    ///
    /// When in `.detected` phase, returns nil to skip expensive pattern matching.
    ///
    /// The sliding buffer stores a `String` tail (not raw `Data`) to avoid splitting
    /// multi-byte UTF-8 characters at chunk boundaries.
    ///
    /// Returns nil if UTF-8 decoding fails or matching should be skipped.
    /// - Parameter now: Current time. Pass explicitly for testability; defaults to `Date()`.
    public mutating func prepareHaystack(chunk: Data, now: Date = Date()) -> String? {
        if phase == .detected {
            return nil
        }

        if phase == .redetecting {
            if let deadline = redetectionDeadline, now >= deadline {
                // Retry window exhausted — give up re-detection
                phase = .scanning
                currentApp = nil
                detectedAt = nil
                redetectionDeadline = nil
                return nil
            }
        }

        // Decode chunk to String (UTF-8). On failure, try lossy replacement so
        // a single bad byte doesn't silently disable detection for the chunk.
        let chunkString: String
        if let decoded = String(data: chunk.prefix(2048), encoding: .utf8) {
            chunkString = decoded
        } else {
            utf8DecodeFailures += 1
            // Lossy fallback: replace invalid sequences with U+FFFD
            chunkString = String(decoding: chunk.prefix(2048), as: UTF8.self)
        }

        // Build haystack: previous tail + current chunk, capped at 2048 characters
        let combined = slidingBufferTail + chunkString
        let haystack = combined.count > 2048
            ? String(combined.suffix(2048))
            : combined

        // Update tail with end of current chunk (character-safe, no UTF-8 splitting)
        slidingBufferTail = String(chunkString.suffix(bufferTailCapacity))

        return haystack.lowercased()
    }

    // MARK: - State Mutations

    /// Called when pattern matching completes on prepared haystack.
    /// `appName` is the matched tool name, or nil if no match.
    /// `authoritativeAppName` is an already-established tool identity from
    /// command detection or restored resume metadata. Output matching is
    /// treated as confirmation only when it agrees with that provider.
    /// Returns true if the state changed.
    /// - Parameter now: Current time. Pass explicitly for testability; defaults to `Date()`.
    @discardableResult
    public mutating func handleOutputMatch(
        appName: String?,
        authoritativeAppName: String? = nil,
        now: Date = Date()
    ) -> Bool {
        guard let appName else { return false }
        guard Self.shouldAcceptOutputMatch(
            matchedAppName: appName,
            authoritativeAppName: authoritativeAppName
        ) else {
            return false
        }

        switch phase {
        case .scanning:
            // IMPORTANT: When lastDetectedApp is set, output-based matching can only
            // RE-CONFIRM the same tool — never switch to a different one. Without this
            // guard, strings like "openai.com" appearing in code output hijack a Claude
            // session to ChatGPT. This was originally fixed in commit 12a6df5 (Mar 8 2026)
            // inside TerminalSessionModel, lost during the AIDetectionState extraction
            // (commit 6669010, Mar 10), and restored here. Only command-level detection
            // (handleCommand) can switch to a different tool.
            if let last = lastDetectedApp, appName != last { return false }
            return setDetected(appName, now: now)
        case .redetecting:
            // Same guard as .scanning — only the previously detected tool is accepted.
            guard appName == lastDetectedApp else { return false }
            return setDetected(appName, now: now)
        case .restored:
            // Live detection overrides restoration
            return setDetected(appName, now: now)
        case .detected:
            // Already detected — shouldn't reach here (prepareHaystack returns nil)
            return false
        }
    }

    /// Called when a command line is entered that matches a known AI tool.
    /// Always overrides current state (command-line detection is high-confidence).
    /// Returns true if the state changed.
    /// - Parameter now: Current time. Pass explicitly for testability; defaults to `Date()`.
    @discardableResult
    public mutating func handleCommand(appName: String?, now: Date = Date()) -> Bool {
        guard let appName else { return false }
        return setDetected(appName, now: now)
    }

    /// Called when OSC 7 / shell prompt is detected (AI tool returned to prompt).
    /// Implements cooldown: no-ops if within `cooldownSeconds` of last detection.
    /// Returns true if the state changed (cleared or entered redetecting).
    /// - Parameter now: Current time. Pass explicitly for testability; defaults to `Date()`.
    @discardableResult
    public mutating func handlePromptReturn(now: Date = Date()) -> Bool {
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
            let elapsed = now.timeIntervalSince(detectedAt)
            if elapsed < cooldownSeconds {
                return false
            }
        }

        // Transition to redetecting (or scanning if no previous detection to lock to)
        if lastDetectedApp != nil {
            phase = .redetecting
            redetectionDeadline = now.addingTimeInterval(redetectionWindowSeconds)
        } else {
            phase = .scanning
        }
        currentApp = nil
        detectedAt = nil
        slidingBufferTail = ""
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
        redetectionDeadline = nil
        slidingBufferTail = ""
        return true
    }

    // MARK: - Internal (test support)

    /// Creates a state in `.redetecting` phase for unit testing.
    /// Internal so tests can access via `@testable import`.
    static func makeRedetecting(lastTool: String, deadline: Date = Date().addingTimeInterval(5.0)) -> AIDetectionState {
        var state = AIDetectionState()
        state.currentApp = nil
        state.lastDetectedApp = lastTool
        state.phase = .redetecting
        state.detectedAt = nil
        state.redetectionDeadline = deadline
        return state
    }

    // MARK: - Private

    static func shouldAcceptOutputMatch(
        matchedAppName: String?,
        authoritativeAppName: String?
    ) -> Bool {
        guard let matchedAppName else { return false }
        guard let authoritativeAppName else { return true }
        guard let matchedProvider = AIResumeParser.normalizeProviderName(matchedAppName),
              let authoritativeProvider = AIResumeParser.normalizeProviderName(authoritativeAppName) else {
            return true
        }
        return matchedProvider == authoritativeProvider
    }

    private mutating func setDetected(_ appName: String, now: Date = Date()) -> Bool {
        currentApp = appName
        lastDetectedApp = appName
        phase = .detected
        detectedAt = now
        redetectionDeadline = nil
        slidingBufferTail = ""
        return true
    }
}
