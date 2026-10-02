import XCTest
import Chau7Core

final class AnalyticsTimestampTests: XCTestCase {
    func testPreservesFractionalBasicAndOffsetTimestamps() throws {
        for timestamp in [
            "2026-10-02T18:00:00.250Z",
            "2026-10-02T18:00:01Z",
            "2026-10-02T20:00:00.123+02:00",
            "2026-10-02T13:00:00-05:00",
            "2026-10-02T18:00:00.123456Z"
        ] {
            let expected = try XCTUnwrap(DateFormatters.parseISO8601(timestamp))
            let actual = try XCTUnwrap(DateFormatters.parseAnalyticsTimestamp(timestamp))
            XCTAssertEqual(actual.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001, timestamp)
        }
    }

    func testRejectsMalformedTimestamps() {
        for timestamp in ["", "invalid", "2026-10-02", "2026-99-99T00:00:00Z"] {
            XCTAssertNil(DateFormatters.parseAnalyticsTimestamp(timestamp), timestamp)
        }
    }
}
