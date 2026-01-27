import XCTest
import Chau7Core

final class RemoteFrameTests: XCTestCase {
    func testEncodeDecodeRoundTrip() throws {
        let payload = Data([0x01, 0x02, 0x03, 0x04])
        let frame = RemoteFrame(
            version: 1,
            type: RemoteFrameType.output.rawValue,
            flags: 0,
            reserved: 0,
            tabID: 42,
            seq: 9,
            payload: payload
        )

        let encoded = frame.encode()
        let decoded = try RemoteFrame.decode(from: encoded)

        XCTAssertEqual(decoded, frame)
    }

    func testDecodeRejectsShortData() {
        let data = Data([0x01, 0x02])
        XCTAssertThrowsError(try RemoteFrame.decode(from: data))
    }

    func testDecodeRejectsInvalidLength() {
        var data = Data()
        data.append(contentsOf: [1, 2, 3, 4])
        data.append(contentsOf: [0, 0, 0, 0]) // tabID
        data.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0]) // seq
        data.append(contentsOf: [10, 0, 0, 0]) // payload_len=10
        data.append(contentsOf: [1, 2]) // actual payload shorter

        XCTAssertThrowsError(try RemoteFrame.decode(from: data))
    }
}
