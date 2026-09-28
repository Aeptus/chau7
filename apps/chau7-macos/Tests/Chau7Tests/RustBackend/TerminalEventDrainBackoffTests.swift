import XCTest
@testable import Chau7

/// Regression coverage for the `TerminalEventDrain` backoff.
///
/// The bug: when a view had no Rust terminal yet, the drain loop slept a fixed
/// 50 ms and looped. A drain started for a view whose terminal creation failed
/// — and which was therefore never stopped — woke 20x a second for the life of
/// the view. Startup latency was unaffected (the drain is normally started
/// after the terminal exists), so the only observable effect was the wasted
/// wakeups, which is exactly the kind of thing that shows up as "Chau7 is
/// mysteriously using CPU with nothing happening".
final class TerminalEventDrainBackoffTests: XCTestCase {
    private let initial: TimeInterval = 0.05
    private let maximum: TimeInterval = 0.25

    private func interval(after passes: Int) -> TimeInterval {
        TerminalEventDrain.pollTimeoutInterval(
            afterMissingPasses: passes,
            initialSeconds: initial,
            maxSeconds: maximum
        )
    }

    /// The first pass must not back off at all, otherwise a legitimately slow
    /// terminal creation would show a visible startup delay.
    func testFirstPassIsUnthrottled() {
        XCTAssertEqual(interval(after: 0), initial)
        XCTAssertEqual(interval(after: 1), initial)
    }

    func testSubsequentPassesBackOffExponentially() {
        XCTAssertEqual(interval(after: 2), initial * 2, accuracy: 0.0001)
        XCTAssertEqual(interval(after: 3), initial * 4, accuracy: 0.0001)
    }

    /// The cap is what actually bounds the damage; without it a long-lived
    /// failed view would still be doing hundreds of wakeups a minute.
    func testConvergesToCap() {
        XCTAssertEqual(interval(after: 4), maximum, accuracy: 0.0001)
        XCTAssertEqual(interval(after: 40), maximum, accuracy: 0.0001)
        XCTAssertEqual(interval(after: 10000), maximum, accuracy: 0.0001)
    }

    /// The interval is a sleep, so it must never be zero or negative —
    /// otherwise the "backoff" becomes a busy loop, which is the exact failure
    /// mode being fixed.
    func testIntervalIsAlwaysPositive() {
        for passes in 0 ... 64 {
            XCTAssertGreaterThan(interval(after: passes), 0, "passes=\(passes)")
        }
    }

    /// A pathological caller must not be able to produce a non-finite sleep.
    func testExtremeInputsStayFinite() {
        XCTAssertEqual(interval(after: Int.max), maximum, accuracy: 0.0001)
        XCTAssertEqual(interval(after: -5), initial, accuracy: 0.0001)
    }
}
