import XCTest
@testable import Chau7Core

final class SessionRecordingTests: XCTestCase {

    // MARK: - RecordedFrame Creation

    func testRecordedFrameCreation() {
        let data = Data("hello world".utf8)
        let frame = RecordedFrame(data: data)

        XCTAssertEqual(frame.data, data)
        XCTAssertEqual(frame.eventType, .output)
        XCTAssertNotNil(frame.id)
        XCTAssertNotNil(frame.timestamp)
    }

    func testRecordedFrameWithEventType() {
        let data = Data([0x1B, 0x5B])
        let frame = RecordedFrame(data: data, eventType: .resize)

        XCTAssertEqual(frame.eventType, .resize)
        XCTAssertEqual(frame.data, data)
    }

    func testRecordedFrameWithCustomID() {
        let id = UUID()
        let ts = Date()
        let data = Data("test".utf8)
        let frame = RecordedFrame(id: id, timestamp: ts, data: data, eventType: .commandStart)

        XCTAssertEqual(frame.id, id)
        XCTAssertEqual(frame.timestamp, ts)
        XCTAssertEqual(frame.eventType, .commandStart)
    }

    // MARK: - RecordedFrame Codable

    func testRecordedFrameEncodeDecode() throws {
        let original = RecordedFrame(data: Data("encode test".utf8), eventType: .input)

        let encoder = JSONEncoder()
        let encoded = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(RecordedFrame.self, from: encoded)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.data, original.data)
        XCTAssertEqual(decoded.eventType, original.eventType)
        // Date comparison with small tolerance for encoding precision
        XCTAssertEqual(
            decoded.timestamp.timeIntervalSince1970,
            original.timestamp.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testRecordedFrameArrayEncodeDecode() throws {
        let frames = [
            RecordedFrame(data: Data("frame1".utf8), eventType: .output),
            RecordedFrame(data: Data("frame2".utf8), eventType: .commandStart),
            RecordedFrame(data: Data("frame3".utf8), eventType: .commandEnd),
        ]

        let encoder = JSONEncoder()
        let encoded = try encoder.encode(frames)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode([RecordedFrame].self, from: encoded)

        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(decoded[0].eventType, .output)
        XCTAssertEqual(decoded[1].eventType, .commandStart)
        XCTAssertEqual(decoded[2].eventType, .commandEnd)
    }

    // MARK: - FrameEventType

    func testFrameEventTypeRawValues() {
        XCTAssertEqual(FrameEventType.output.rawValue, "output")
        XCTAssertEqual(FrameEventType.input.rawValue, "input")
        XCTAssertEqual(FrameEventType.resize.rawValue, "resize")
        XCTAssertEqual(FrameEventType.commandStart.rawValue, "commandStart")
        XCTAssertEqual(FrameEventType.commandEnd.rawValue, "commandEnd")
        XCTAssertEqual(FrameEventType.marker.rawValue, "marker")
    }

    func testFrameEventTypeCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for eventType in [FrameEventType.output, .input, .resize, .commandStart, .commandEnd, .marker] {
            let encoded = try encoder.encode(eventType)
            let decoded = try decoder.decode(FrameEventType.self, from: encoded)
            XCTAssertEqual(decoded, eventType)
        }
    }

    // MARK: - SessionRecordingMeta Duration

    func testDurationNilWhenNoEndTime() {
        let meta = SessionRecordingMeta(title: "Test")
        XCTAssertNil(meta.duration)
    }

    func testDurationCalculation() {
        let start = Date()
        var meta = SessionRecordingMeta(startTime: start, title: "Test")
        meta.endTime = start.addingTimeInterval(125.0) // 2m 5s

        XCTAssertEqual(meta.duration!, 125.0, accuracy: 0.001)
    }

    func testDurationZeroWhenSameTime() {
        let start = Date()
        var meta = SessionRecordingMeta(startTime: start, title: "Test")
        meta.endTime = start

        XCTAssertEqual(meta.duration!, 0.0, accuracy: 0.001)
    }

    // MARK: - SessionRecordingMeta durationString

    func testDurationStringRecording() {
        let meta = SessionRecordingMeta(title: "Test")
        XCTAssertEqual(meta.durationString, "recording...")
    }

    func testDurationStringZero() {
        let start = Date()
        var meta = SessionRecordingMeta(startTime: start, title: "Test")
        meta.endTime = start
        XCTAssertEqual(meta.durationString, "0:00")
    }

    func testDurationStringSeconds() {
        let start = Date()
        var meta = SessionRecordingMeta(startTime: start, title: "Test")
        meta.endTime = start.addingTimeInterval(45.0)
        XCTAssertEqual(meta.durationString, "0:45")
    }

    func testDurationStringMinutes() {
        let start = Date()
        var meta = SessionRecordingMeta(startTime: start, title: "Test")
        meta.endTime = start.addingTimeInterval(125.0) // 2m 5s
        XCTAssertEqual(meta.durationString, "2:05")
    }

    func testDurationStringLong() {
        let start = Date()
        var meta = SessionRecordingMeta(startTime: start, title: "Test")
        meta.endTime = start.addingTimeInterval(3661.0) // 61m 1s
        XCTAssertEqual(meta.durationString, "61:01")
    }

    // MARK: - SessionRecordingMeta Codable

    func testMetaEncodeDecode() throws {
        let start = Date()
        var original = SessionRecordingMeta(startTime: start, title: "My Recording")
        original.endTime = start.addingTimeInterval(300)
        original.shellType = "zsh"
        original.directory = "/Users/test"
        original.frameCount = 42
        original.totalBytes = 1024

        let encoder = JSONEncoder()
        let encoded = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SessionRecordingMeta.self, from: encoded)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.title, "My Recording")
        XCTAssertEqual(decoded.shellType, "zsh")
        XCTAssertEqual(decoded.directory, "/Users/test")
        XCTAssertEqual(decoded.frameCount, 42)
        XCTAssertEqual(decoded.totalBytes, 1024)
    }

    // MARK: - SessionRecordingMeta Defaults

    func testMetaDefaults() {
        let meta = SessionRecordingMeta()
        XCTAssertEqual(meta.title, "Recording")
        XCTAssertEqual(meta.frameCount, 0)
        XCTAssertEqual(meta.totalBytes, 0)
        XCTAssertNil(meta.endTime)
        XCTAssertNil(meta.shellType)
        XCTAssertNil(meta.directory)
    }

    func testMetaCustomTitle() {
        let meta = SessionRecordingMeta(title: "Debug Session")
        XCTAssertEqual(meta.title, "Debug Session")
    }
}
