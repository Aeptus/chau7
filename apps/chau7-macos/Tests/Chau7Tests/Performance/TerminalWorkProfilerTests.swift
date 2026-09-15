import XCTest
@testable import Chau7

final class TerminalWorkProfilerTests: XCTestCase {
    private final class Recorder: PerformanceTelemetryRecording {
        var records: [(category: String, fields: [String: Any], date: Date)] = []

        func record(category: String, fields: [String: Any], at date: Date) {
            records.append((category, fields, date))
        }
    }

    func testAggregatesByOperationPhaseVisibilityAndCaller() {
        let profiler = TerminalWorkProfiler(logInterval: .infinity)
        let hiddenDrain = TerminalWorkContext(
            renderPhase: "hidden",
            visibility: "drainOnly",
            caller: "backgroundDrain"
        )
        let visibleRender = TerminalWorkContext(
            renderPhase: "active",
            visibility: "visible",
            caller: "cpuRenderer"
        )

        profiler.record(
            .getLastOutput,
            context: hiddenDrain,
            durationMs: 2,
            bytes: 100,
            ranOnMainThread: false
        )
        profiler.record(
            .getLastOutput,
            context: hiddenDrain,
            durationMs: 3,
            bytes: 250,
            ranOnMainThread: true
        )
        profiler.record(
            .getGrid,
            context: visibleRender,
            durationMs: 4,
            bytes: 4096,
            ranOnMainThread: true
        )

        let snapshot = profiler.snapshot()
        XCTAssertEqual(snapshot.entries.count, 2)
        let output = snapshot.entries[
            TerminalWorkProfiler.Key(operation: .getLastOutput, context: hiddenDrain)
        ]
        XCTAssertEqual(output?.count, 2)
        XCTAssertEqual(output?.bytes, 350)
        XCTAssertEqual(output?.totalDurationMs, 5)
        XCTAssertEqual(output?.mainThreadDurationMs, 3)
        XCTAssertEqual(output?.maxDurationMs, 3)
    }

    func testMeasureRecordsReturnedBytes() {
        let profiler = TerminalWorkProfiler(logInterval: .infinity)
        let context = TerminalWorkContext(
            renderPhase: "warm",
            visibility: "drainOnly",
            caller: "idleScrollbackFlush"
        )

        let result = profiler.measure(
            .fullBufferCapture,
            context: context,
            ranOnMainThread: false,
            bytes: { $0.count }
        ) {
            Data(repeating: 0x41, count: 2048)
        }

        XCTAssertEqual(result.count, 2048)
        let aggregate = profiler.snapshot().entries[
            TerminalWorkProfiler.Key(operation: .fullBufferCapture, context: context)
        ]
        XCTAssertEqual(aggregate?.count, 1)
        XCTAssertEqual(aggregate?.bytes, 2048)
        XCTAssertEqual(aggregate?.mainThreadDurationMs, 0)
    }

    func testIntervalFlushWritesOneStructuredAggregateOutsideOperationalLog() throws {
        var clock = Date(timeIntervalSince1970: 1000)
        let recorder = Recorder()
        let profiler = TerminalWorkProfiler(
            logInterval: 60,
            now: { clock },
            telemetry: recorder
        )
        let context = TerminalWorkContext(
            renderPhase: "active",
            visibility: "visible",
            caller: "metal"
        )
        profiler.record(.getGrid, context: context, durationMs: 2, bytes: 100)
        clock = clock.addingTimeInterval(60)
        profiler.record(.getGrid, context: context, durationMs: 3, bytes: 200)

        let record = try XCTUnwrap(recorder.records.first)
        XCTAssertEqual(recorder.records.count, 1)
        XCTAssertEqual(record.category, "terminal_work")
        let entries = try XCTUnwrap(record.fields["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0]["count"] as? Int, 2)
        XCTAssertEqual(entries[0]["bytes"] as? Int, 300)
    }
}
