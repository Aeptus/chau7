import XCTest
import AppKit
import Metal
#if !SWIFT_PACKAGE
@testable import Chau7

@MainActor
final class MetalTerminalRendererTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MetalTerminalRenderer.resetSharedAtlasesForTesting()
    }

    func testClonedSharedAtlasPreservesCacheMetadata() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable on this host")
        }

        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        guard let firstRenderer = MetalTerminalRenderer(device: device) else {
            XCTFail("Failed to create the first Metal renderer")
            return
        }
        firstRenderer.setFont(nsFont: font, scaleFactor: 1.0)
        let firstState = firstRenderer.atlasCacheStateForTesting()

        XCTAssertGreaterThan(
            firstState.glyphCount,
            0,
            "The initial renderer should populate the shared atlas with ASCII glyphs"
        )

        guard let secondRenderer = MetalTerminalRenderer(device: device) else {
            XCTFail("Failed to create the second Metal renderer")
            return
        }
        secondRenderer.setFont(nsFont: font, scaleFactor: 1.0)
        let secondState = secondRenderer.atlasCacheStateForTesting()

        XCTAssertEqual(
            secondState.glyphCount,
            firstState.glyphCount,
            "A cloned shared atlas must preserve the cached glyph metadata"
        )
        XCTAssertEqual(
            secondState.packX,
            firstState.packX,
            accuracy: 0.001,
            "A cloned shared atlas must keep the packing cursor in sync with the copied bitmap"
        )
        XCTAssertEqual(
            secondState.packY,
            firstState.packY,
            accuracy: 0.001,
            "A cloned shared atlas must keep the Y packing cursor in sync with the copied bitmap"
        )
        XCTAssertEqual(
            secondState.packRowHeight,
            firstState.packRowHeight,
            accuracy: 0.001,
            "A cloned shared atlas must keep the row height metadata in sync with the copied bitmap"
        )
    }
}
#endif
