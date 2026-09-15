import XCTest
@testable import Chau7

final class TerminalMemoryReportTests: XCTestCase {
    private func entry(
        title: String,
        ringBytes: Int,
        searchCacheBytes: Int = 0,
        cpuFallbackBytes: Int = 0,
        isTUI: Bool = false
    ) -> TerminalMemoryReport.TabEntry {
        TerminalMemoryReport.TabEntry(
            id: UUID().uuidString,
            title: title,
            renderPhase: "warm",
            isTUIProtected: isTUI,
            alternateScreenActive: false,
            historyRows: 10000,
            estimatedRingBytes: ringBytes,
            sessionCachedBufferBytes: searchCacheBytes,
            sessionCachedRemoteTextBytes: 0,
            restorationCacheBytes: 0,
            cachedBufferLineCount: 0,
            cpuFallbackBytes: cpuFallbackBytes
        )
    }

    func testTotalsAggregateAcrossAttributionBuckets() {
        let report = TerminalMemoryReport(
            capturedAt: Date(),
            tabs: [
                entry(title: "big", ringBytes: 40_000_000, searchCacheBytes: 2_000_000),
                entry(title: "small", ringBytes: 1_000_000, cpuFallbackBytes: 500_000)
            ],
            renderer: nil,
            processFootprintMB: nil
        )

        XCTAssertEqual(report.tabs[0].totalBytes, 42_000_000)
        XCTAssertEqual(report.tabs[1].totalBytes, 1_500_000)
        XCTAssertEqual(report.totalTabBytes, 43_500_000)
    }

    func testFormattedReportIncludesTabsAndRenderer() {
        let renderer = TerminalMemoryReport.RendererEntry(
            gridCols: 200,
            gridRows: 50,
            instanceBufferBytes: 4_000_000,
            atlasTextureBytes: 16_777_216,
            atlasContextBytes: 16_777_216,
            tripleBufferBytes: 1_920_000,
            glyphCacheEntries: 321
        )
        let report = TerminalMemoryReport(
            capturedAt: Date(),
            tabs: [entry(title: "agent tab", ringBytes: 40_000_000, isTUI: true)],
            renderer: renderer,
            processFootprintMB: 1234.5
        )

        let text = report.formatted()
        XCTAssertTrue(text.contains("process footprint: 1234.5 MB"))
        XCTAssertTrue(text.contains("agent tab"))
        XCTAssertTrue(text.contains("tui"), "TUI protection must be visible in the flags column")
        XCTAssertTrue(text.contains("38.1MB"), "ring bytes must render in MB")
        XCTAssertTrue(text.contains("renderer (per window, grid 200x50)"))
        XCTAssertTrue(text.contains("glyph cache entries: 321"))
        XCTAssertEqual(renderer.totalBytes, 4_000_000 + 16_777_216 + 16_777_216 + 1_920_000)
    }

    func testFormatBytesUnits() {
        XCTAssertEqual(TerminalMemoryReport.formatBytes(512), "512B")
        XCTAssertEqual(TerminalMemoryReport.formatBytes(2048), "2.0KB")
        XCTAssertEqual(TerminalMemoryReport.formatBytes(41_943_040), "40.0MB")
        XCTAssertEqual(TerminalMemoryReport.formatBytes(2_147_483_648), "2.00GB")
    }
}
