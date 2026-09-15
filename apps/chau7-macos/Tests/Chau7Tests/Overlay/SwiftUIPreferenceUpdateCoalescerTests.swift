import XCTest
@testable import Chau7

@MainActor
final class SwiftUIPreferenceUpdateCoalescerTests: XCTestCase {
    func testCoalescesEachPreferenceChannelOntoNextMainTurn() async {
        let coalescer = SwiftUIPreferenceUpdateCoalescer()
        var values: [String] = []

        coalescer.schedule(.tabBarSize) { values.append("stale") }
        coalescer.schedule(.tabBarSize) { values.append("latest") }
        coalescer.schedule(.tabBarFrame) { values.append("frame") }

        XCTAssertTrue(values.isEmpty, "preference mutation must not run during the view update")
        await Task.yield()

        XCTAssertEqual(values, ["latest", "frame"])
    }
}
