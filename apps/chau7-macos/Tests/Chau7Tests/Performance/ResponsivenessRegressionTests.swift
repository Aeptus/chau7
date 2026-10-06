import XCTest
import Chau7Core
@testable import Chau7

/// These are hard budgets, unlike XCTest measure() without a saved baseline.
/// They run in the existing Swift CI suite and require no extra Actions job.
final class ResponsivenessRegressionTests: XCTestCase {
    private static let viewportCount = 19
    private static let repetitions = 10
    private static let sampleCount = viewportCount * repetitions

    func testGridEncodingAndCacheBudgetAcrossNineteenViewportSwitches() throws {
        let cols: UInt16 = 160
        let rows: UInt16 = 50
        let frame = makeFrame(cols: cols, rows: rows)
        let update = RemoteGridUpdate(
            baseGeneration: 0,
            generation: 1,
            fullRefresh: true,
            rowIndices: Array(0 ..< rows),
            snapshot: frame
        )
        var cache = RemoteGridSnapshotCache()
        // Warm up Swift/Foundation before measuring.
        _ = cache.encode(update)
        var milliseconds: [Double] = []
        // Ten sweeps separate p95/p99 ranks and tolerate an isolated scheduler pause.
        for _ in 0 ..< Self.sampleCount {
            cache.reset()
            let started = ProcessInfo.processInfo.systemUptime
            let payload = try XCTUnwrap(cache.encode(update))
            milliseconds.append((ProcessInfo.processInfo.systemUptime - started) * 1000)
            let decoded = try RemoteTerminalGridSnapshot.decode(from: payload)
            XCTAssertTrue(decoded.isValid)
            XCTAssertTrue(String(decoding: decoded.clusters, as: UTF8.self).contains("👩🏽‍💻"))
            XCTAssertLessThanOrEqual(cache.retainedBytes, RemoteGridSnapshotCache.defaultMaximumBytes)
        }
        assertLatencyBudget(milliseconds, operation: "remote encoding")

    }

    func testBackgroundEncodingAllowsMainQueueToProcessInputProbes() async {
        let worker = RemoteGridSnapshotWorker()
        let frame = makeFrame(cols: 240, rows: 100)
        let update = RemoteGridUpdate(
            baseGeneration: 0,
            generation: 1,
            fullRefresh: true,
            rowIndices: Array(0 ..< 100),
            snapshot: frame
        )
        var milliseconds: [Double] = []
        for index in 0 ..< Self.sampleCount {
            let encoded = expectation(description: "encoded frame \(index)")
            worker.encode(update, scope: "viewport-\(index % Self.viewportCount)") { result in
                XCTAssertFalse(Thread.isMainThread)
                XCTAssertNotNil(result.payload)
                encoded.fulfill()
            }
            let started = ProcessInfo.processInfo.systemUptime
            let latency = await withCheckedContinuation { continuation in
                DispatchQueue.main.async {
                    continuation.resume(returning: (ProcessInfo.processInfo.systemUptime - started) * 1000)
                }
            }
            milliseconds.append(latency)
            await fulfillment(of: [encoded], timeout: 5)
        }
        assertLatencyBudget(milliseconds, operation: "main queue input probe")
    }

    func testPercentilesHaveDistinctRanksAndTolerateOneSchedulerPause() {
        var samples = (0 ..< Self.sampleCount).map(Double.init)
        let ordinary = percentiles(samples)
        XCTAssertEqual(ordinary.p95, 180)
        XCTAssertEqual(ordinary.p99, 188)
        samples[0] = 1000
        let paused = percentiles(samples)
        XCTAssertEqual(paused.p95, 181)
        XCTAssertEqual(paused.p99, 189)
        XCTAssertLessThan(paused.p99, 1000)
    }

    private func assertLatencyBudget(_ samples: [Double], operation: String) {
        XCTAssertGreaterThanOrEqual(samples.count, 100, "percentile budgets need distinct tail ranks")
        let latency = percentiles(samples)
        Log.info("Responsiveness benchmark \(operation): samples=\(samples.count) p95=\(latency.p95)ms p99=\(latency.p99)ms")
        XCTAssertLessThan(latency.p95, 50, "\(operation) p95 budget")
        XCTAssertLessThan(latency.p99, 100, "\(operation) p99 budget")
    }

    private func percentiles(_ samples: [Double]) -> (p95: Double, p99: Double) {
        guard !samples.isEmpty else { return (.infinity, .infinity) }
        let sorted = samples.sorted()
        return (
            sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1],
            sorted[Int(ceil(Double(sorted.count) * 0.99)) - 1]
        )
    }

    private func makeFrame(cols: UInt16, rows: UInt16) -> RemoteTerminalGridSnapshot {
        let clusters = Data("xé👩🏽‍💻".utf8)
        let offsets = [0, 1, 3, 0]
        let lengths = [1, 2, "👩🏽‍💻".utf8.count, 0]
        var cells = Data(repeating: 0, count: Int(cols) * Int(rows) * 20)
        for index in 0 ..< Int(cols) * Int(rows) {
            let kind = index % 4
            let start = index * 20
            cells[start] = UInt8(offsets[kind])
            cells[start + 10] = UInt8(lengths[kind])
            cells[start + 12] = kind == 3 ? 0 : (kind == 2 ? 2 : 1)
            cells[start + 13] = kind == 3 ? 1 : 0
        }
        return RemoteTerminalGridSnapshot(
            cols: cols, rows: rows, cursorCol: 0, cursorRow: 0, cursorVisible: true,
            scrollbackRows: 5000, displayOffset: 0, cells: cells, clusters: clusters
        )
    }
}
