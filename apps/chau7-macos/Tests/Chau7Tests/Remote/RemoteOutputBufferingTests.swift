import XCTest
@testable import Chau7Core

final class RemoteOutputBufferingTests: XCTestCase {
    func testTrimRetainedTextKeepsSuffixWithinByteLimit() {
        let oversized = String(repeating: "a", count: RemoteOutputTuning.maxRetainedBytes + 10)

        let trimmed = RemoteOutputTuning.trimRetainedText(oversized)

        XCTAssertEqual(trimmed.utf8.count, RemoteOutputTuning.maxRetainedBytes)
        XCTAssertEqual(trimmed, String(repeating: "a", count: RemoteOutputTuning.maxRetainedBytes))
    }

    func testCapIncomingFrameRespectsFrameLimit() {
        let data = Data(repeating: 0x41, count: RemoteOutputTuning.maxIncomingFrameBytes + 10)

        let capped = RemoteOutputTuning.capIncomingFrame(data)

        XCTAssertEqual(capped.count, RemoteOutputTuning.maxIncomingFrameBytes)
    }

    func testPendingBufferDrainAllReturnsSortedPairs() {
        var buffer = RemotePendingOutputBuffer<Data>()
        buffer.append(Data("b".utf8), to: 2) { existing, chunk in existing.append(chunk) }
        buffer.append(Data("a".utf8), to: 1) { existing, chunk in existing.append(chunk) }

        let drained = buffer.drainAll(sortedByTabID: true)

        XCTAssertEqual(drained.map(\.0), [1, 2])
        XCTAssertEqual(drained.map { String(decoding: $0.1, as: UTF8.self) }, ["a", "b"])
        XCTAssertTrue(buffer.isEmpty)
    }

    func testPendingBufferRetainDropsHiddenTabs() {
        var buffer = RemotePendingOutputBuffer<String>()
        buffer.append("one", to: 1) { existing, chunk in existing.append(chunk) }
        buffer.append("two", to: 2) { existing, chunk in existing.append(chunk) }

        buffer.retain(only: [2])

        XCTAssertNil(buffer[1])
        XCTAssertEqual(buffer[2], "two")
    }
}
