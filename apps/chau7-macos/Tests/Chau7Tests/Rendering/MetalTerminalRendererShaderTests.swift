import Metal
import XCTest
@testable import Chau7

final class MetalTerminalRendererShaderTests: XCTestCase {
    func testShaderCompilesWithLinkUnderlineUniform() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable in this test environment")
        }

        XCTAssertNotNil(MetalTerminalRenderer(device: device))
    }
}
