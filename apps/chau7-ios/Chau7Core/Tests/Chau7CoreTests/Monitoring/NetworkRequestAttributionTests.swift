import Foundation
import XCTest
@testable import Chau7Core

final class NetworkRequestAttributionTests: XCTestCase {
    func testLogFieldsExposeComponentAndHostWithoutSensitiveURLParts() throws {
        let url = try XCTUnwrap(URL(string: "https://user:secret@Status.OpenAI.com/private/path?token=abc#fragment"))
        let attribution = NetworkRequestAttribution(component: "provider_status", url: url)

        XCTAssertEqual(attribution.logFields, "component=provider_status host=status.openai.com")
        XCTAssertFalse(attribution.logFields.contains("secret"))
        XCTAssertFalse(attribution.logFields.contains("token"))
        XCTAssertFalse(attribution.logFields.contains("private"))
    }
}
