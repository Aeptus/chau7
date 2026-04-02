import Foundation
import Chau7Core

/// Records terminal session output for timeline scrubbing and replay.
/// Captures terminal output frames with timestamps, enabling users to
/// scrub backwards through their session to find previous output.
///
/// Storage: ~/Library/Application Support/Chau7/recordings/
/// Format: Binary file with JSON metadata sidecar
@MainActor
@Observable
final class SessionRecorder {
    var isRecording = false
    var currentRecording: SessionRecordingMeta?
    var recordings: [SessionRecordingMeta] = []

    /// Maximum recording size in bytes (default 50MB)
    var maxRecordingBytes = 50 * 1024 * 1024

    /// Frame buffer for current recording
    private var frames: [RecordedFrame] = []
    private var totalBytes = 0

    private var recordingsDir: URL {
        RuntimeIsolation.appSupportDirectory(named: "Chau7")
            .appendingPathComponent("recordings", isDirectory: true)
    }

    init() {
        do {
            try FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        } catch {
            Log.error("SessionRecorder: failed to create recordings dir: \(error)")
        }
        loadRecordingsList()
        Log.info("SessionRecorder initialized: \(recordings.count) existing recordings")
    }

    // MARK: - Recording Lifecycle

    func startRecording(title: String = "Session") {
        currentRecording = SessionRecordingMeta(title: title)
        frames = []
        totalBytes = 0
        isRecording = true
        Log.info("SessionRecorder: started recording '\(title)'")
    }

    func recordFrame(data: Data, eventType: FrameEventType = .output) {
        guard isRecording else { return }
        guard totalBytes + data.count <= maxRecordingBytes else {
            Log.warn("SessionRecorder: max size reached, stopping")
            stopRecording()
            return
        }

        let frame = RecordedFrame(data: data, eventType: eventType)
        frames.append(frame)
        totalBytes += data.count
        currentRecording?.frameCount = frames.count
        currentRecording?.totalBytes = totalBytes
    }

    func stopRecording() {
        guard isRecording, var meta = currentRecording else { return }
        meta.endTime = Date()
        meta.frameCount = frames.count
        meta.totalBytes = totalBytes

        saveRecording(meta: meta, frames: frames)
        recordings.insert(meta, at: 0)

        isRecording = false
        currentRecording = nil
        frames = []
        Log.info("SessionRecorder: stopped recording, \(meta.frameCount) frames, \(meta.totalBytes) bytes")
    }

    // MARK: - Management

    func deleteRecording(id: UUID) {
        recordings.removeAll { $0.id == id }
        let metaFile = recordingsDir.appendingPathComponent("\(id.uuidString).json")
        let dataFile = recordingsDir.appendingPathComponent("\(id.uuidString).bin")
        do { try FileManager.default.removeItem(at: metaFile) } catch { Log.error("SessionRecorder: delete meta \(id): \(error)") }
        do { try FileManager.default.removeItem(at: dataFile) } catch { Log.error("SessionRecorder: delete data \(id): \(error)") }
        Log.info("SessionRecorder: deleted recording \(id)")
    }

    func loadFrames(recordingID: UUID) -> [RecordedFrame] {
        let dataFile = recordingsDir.appendingPathComponent("\(recordingID.uuidString).bin")
        guard let raw = try? Data(contentsOf: dataFile) else { return [] }
        return Self.decodeFrames(from: raw)
    }

    // MARK: - Persistence

    /// Binary format: "CH7R" magic (4 bytes) + version UInt8 (1 byte)
    /// then per frame: Float64 timestamp (8) + UInt8 eventType (1) + UInt32 dataLen (4) + data bytes
    private static let magic: [UInt8] = [0x43, 0x48, 0x37, 0x52] // "CH7R"
    private static let formatVersion: UInt8 = 1

    private func saveRecording(meta: SessionRecordingMeta, frames: [RecordedFrame]) {
        let metaFile = recordingsDir.appendingPathComponent("\(meta.id.uuidString).json")
        let dataFile = recordingsDir.appendingPathComponent("\(meta.id.uuidString).bin")

        do {
            let metaData = try JSONEncoder().encode(meta)
            try metaData.write(to: metaFile)
        } catch {
            Log.error("SessionRecorder: failed to save meta: \(error)")
        }
        do {
            try Self.encodeFrames(frames).write(to: dataFile)
        } catch {
            Log.error("SessionRecorder: failed to save data: \(error)")
        }
    }

    static func encodeFrames(_ frames: [RecordedFrame]) -> Data {
        var buf = Data(magic)
        buf.append(formatVersion)
        for frame in frames {
            var ts = frame.timestamp.timeIntervalSince1970
            buf.append(Data(bytes: &ts, count: 8))
            buf.append(Self.eventTypeByte(frame.eventType))
            var len = UInt32(frame.data.count).bigEndian
            buf.append(Data(bytes: &len, count: 4))
            buf.append(frame.data)
        }
        return buf
    }

    static func decodeFrames(from raw: Data) -> [RecordedFrame] {
        // Minimum: 4 (magic) + 1 (version) = 5 bytes header
        guard raw.count >= 5 else { return [] }
        let headerBytes = [UInt8](raw.prefix(4))
        guard headerBytes == magic else {
            // Fall back to legacy JSON format for older recordings
            return (try? JSONDecoder().decode([RecordedFrame].self, from: raw)) ?? []
        }
        // version byte at offset 4 (reserved for future use)
        var offset = 5
        var frames: [RecordedFrame] = []
        while offset + 13 <= raw.count { // 8 (ts) + 1 (type) + 4 (len) = 13 min per frame
            let ts: Float64 = raw[offset ..< offset + 8].withUnsafeBytes { $0.load(as: Float64.self) }
            offset += 8
            let typeByte = raw[offset]
            offset += 1
            let len = raw[offset ..< offset + 4].withUnsafeBytes { UInt32(bigEndian: $0.load(as: UInt32.self)) }
            offset += 4
            guard offset + Int(len) <= raw.count else { break }
            let data = raw[offset ..< offset + Int(len)]
            offset += Int(len)
            frames.append(RecordedFrame(
                timestamp: Date(timeIntervalSince1970: ts),
                data: Data(data),
                eventType: Self.byteToEventType(typeByte)
            ))
        }
        return frames
    }

    private static func eventTypeByte(_ type: FrameEventType) -> UInt8 {
        switch type {
        case .output: return 0
        case .input: return 1
        case .resize: return 2
        case .commandStart: return 3
        case .commandEnd: return 4
        case .marker: return 5
        }
    }

    private static func byteToEventType(_ byte: UInt8) -> FrameEventType {
        switch byte {
        case 0: return .output
        case 1: return .input
        case 2: return .resize
        case 3: return .commandStart
        case 4: return .commandEnd
        case 5: return .marker
        default: return .output
        }
    }

    private func loadRecordingsList() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: recordingsDir, includingPropertiesForKeys: nil) else { return }

        recordings = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> SessionRecordingMeta? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(SessionRecordingMeta.self, from: data)
            }
            .sorted { ($0.startTime) > ($1.startTime) }
    }
}
