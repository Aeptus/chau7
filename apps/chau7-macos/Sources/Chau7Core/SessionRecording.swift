import Foundation

// MARK: - Session Recording Core Types

/// A single recorded frame in a session recording.
/// Captures terminal output at a point in time for replay.
public struct RecordedFrame: Codable, Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let data: Data          // Terminal output bytes
    public let eventType: FrameEventType

    public init(id: UUID = UUID(), timestamp: Date = Date(), data: Data, eventType: FrameEventType = .output) {
        self.id = id
        self.timestamp = timestamp
        self.data = data
        self.eventType = eventType
    }
}

/// The type of event captured in a recorded frame.
public enum FrameEventType: String, Codable, Sendable {
    case output        // Terminal output data
    case input         // User input
    case resize        // Terminal resize
    case commandStart  // Command started
    case commandEnd    // Command ended
    case marker        // User-placed marker
}

/// Metadata for a session recording.
/// Stored as a JSON sidecar alongside the binary frame data.
public struct SessionRecordingMeta: Codable, Identifiable, Sendable {
    public let id: UUID
    public let startTime: Date
    public var endTime: Date?
    public var title: String
    public var shellType: String?
    public var directory: String?
    public var frameCount: Int
    public var totalBytes: Int

    public init(id: UUID = UUID(), startTime: Date = Date(), title: String = "Recording") {
        self.id = id
        self.startTime = startTime
        self.title = title
        self.frameCount = 0
        self.totalBytes = 0
    }

    /// The wall-clock duration of the recording, if it has finished.
    public var duration: TimeInterval? {
        guard let end = endTime else { return nil }
        return end.timeIntervalSince(startTime)
    }

    /// Human-readable duration string (e.g. "2:05" or "recording...").
    public var durationString: String {
        guard let d = duration else { return "recording..." }
        let mins = Int(d) / 60
        let secs = Int(d) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
