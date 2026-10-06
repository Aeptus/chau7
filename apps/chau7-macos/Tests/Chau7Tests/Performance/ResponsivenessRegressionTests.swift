import XCTest
import Chau7Core
@testable import Chau7

/// These are hard budgets, unlike XCTest measure() without a saved baseline.
/// They run in the existing Swift CI suite and require no extra Actions job.
final class ResponsivenessRegressionTests: XCTestCase {
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
        for _ in 0 ..< 19 {
            cache.reset()
            let started = ProcessInfo.processInfo.systemUptime
            let payload = try XCTUnwrap(cache.encode(update))
            milliseconds.append((ProcessInfo.processInfo.systemUptime - started) * 1000)
            let decoded = try RemoteTerminalGridSnapshot.decode(from: payload)
            XCTAssertTrue(decoded.isValid)
            XCTAssertTrue(String(decoding: decoded.clusters, as: UTF8.self).contains("👩🏽‍💻"))
            XCTAssertLessThanOrEqual(cache.retainedBytes, RemoteGridSnapshotCache.defaultMaximumBytes)
        }
        milliseconds.sort()
        let p95 = milliseconds[Int(ceil(Double(milliseconds.count) * 0.95)) - 1]
        let p99 = milliseconds[Int(ceil(Double(milliseconds.count) * 0.99)) - 1]
        Log.info("Remote grid benchmark: p95=\(p95)ms p99=\(p99)ms retained=\(cache.retainedBytes) bytes")
        XCTAssertLessThan(p95, 50, "remote encoding p95 budget")
        XCTAssertLessThan(p99, 100, "remote encoding p99 budget")
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
        for index in 0 ..< 19 {
            let encoded = expectation(description: "encoded frame \(index)")
            let input = expectation(description: "main input probe \(index)")
            worker.encode(update, scope: "viewport-\(index)") { result in
                XCTAssertFalse(Thread.isMainThread)
                XCTAssertNotNil(result.payload)
                encoded.fulfill()
            }
            let started = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async {
                let milliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
                XCTAssertLessThan(milliseconds, 100, "main queue input probe budget during remote encoding")
                input.fulfill()
            }
            await fulfillment(of: [input, encoded], timeout: 5)
        }
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
