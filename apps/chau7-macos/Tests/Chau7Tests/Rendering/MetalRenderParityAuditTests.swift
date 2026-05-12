import XCTest
@testable import Chau7Core

final class MetalRenderParityAuditTests: XCTestCase {
    func testAuditCoversEveryTrackedParityFeature() {
        let auditedFeatures = Set(MetalRenderParityAudit.entries.map(\.feature))

        XCTAssertEqual(auditedFeatures, Set(MetalRenderParityFeature.allCases))
    }

    func testConcreteParityFixesAreMarkedCovered() throws {
        XCTAssertEqual(
            try XCTUnwrap(MetalRenderParityAudit.entry(for: .osc8LinkUnderline)).status,
            .covered
        )
        XCTAssertEqual(
            try XCTUnwrap(MetalRenderParityAudit.entry(for: .localEchoOverlays)).status,
            .covered
        )
        XCTAssertEqual(
            try XCTUnwrap(MetalRenderParityAudit.entry(for: .commandBlockTinting)).status,
            .covered
        )
    }

    func testKnownVisualQAGapsRemainExplicit() throws {
        XCTAssertEqual(
            try XCTUnwrap(MetalRenderParityAudit.entry(for: .wideGlyphs)).status,
            .partial
        )
        XCTAssertEqual(
            try XCTUnwrap(MetalRenderParityAudit.entry(for: .inlineImages)).status,
            .externalOverlay
        )
    }
}
