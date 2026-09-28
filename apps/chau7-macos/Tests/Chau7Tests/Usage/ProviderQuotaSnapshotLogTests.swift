import Foundation
import XCTest
@testable import Chau7

/// Regression coverage for the provider-quota snapshot log's size and read
/// bounds.
///
/// The defect: `~/.chau7/usage/provider-quotas.jsonl` was appended to on every
/// refresh with no cap, no rotation, and no retention, while `loadSnapshots`
/// read the entire file and ran `JSONSerialization` over every line on a 30 s
/// timer — and the caller used only the last 600 s. Parse cost therefore scaled
/// with total history instead of with the window consumed, which is an
/// out-of-memory failure rather than merely a slow one.
final class ProviderQuotaSnapshotLogTests: XCTestCase {
    // MARK: - Read window

    func testSmallFileIsReadWhole() {
        XCTAssertEqual(ProviderQuotaSnapshotLog.readStartOffset(fileSize: 1_000), 0)
        XCTAssertEqual(ProviderQuotaSnapshotLog.readWindowBytes(fileSize: 1_000), 1_000)
    }

    func testFileExactlyAtBudgetIsReadWhole() {
        let budget = ProviderQuotaSnapshotLog.readBudgetBytes
        XCTAssertEqual(ProviderQuotaSnapshotLog.readStartOffset(fileSize: budget), 0)
    }

    /// The whole point: an outgrown file costs a bounded read.
    func testOversizedFileReadsOnlyTheTail() {
        let budget = ProviderQuotaSnapshotLog.readBudgetBytes
        let size = budget * 50
        XCTAssertEqual(ProviderQuotaSnapshotLog.readStartOffset(fileSize: size), size - budget)
        XCTAssertEqual(ProviderQuotaSnapshotLog.readWindowBytes(fileSize: size), budget)
    }

    /// The budget must exceed the 600 s consumption window many times over, or
    /// truncation could starve the reader. At ~400 B per snapshot line the
    /// budget holds ~1300 lines against the ~20 a 30 s cadence produces.
    func testBudgetIsAmpleForTheConsumptionWindow() {
        let bytesPerLine = 400
        let linesHeld = ProviderQuotaSnapshotLog.readBudgetBytes / bytesPerLine
        let linesNeededForWindow = Int(600 / 30) * 4 // 4 providers, 1 sample each

        XCTAssertGreaterThan(
            linesHeld, linesNeededForWindow * 10,
            "budget holds only ~\(linesHeld) lines; too close to the window it must cover"
        )
    }

    // MARK: - Edge cases

    func testEmptyFileReadsNothing() {
        XCTAssertEqual(ProviderQuotaSnapshotLog.readStartOffset(fileSize: 0), 0)
        XCTAssertEqual(ProviderQuotaSnapshotLog.readWindowBytes(fileSize: 0), 0)
        XCTAssertTrue(
            ProviderQuotaSnapshotLog.alignedTail(Data(), startedMidFile: true).isEmpty
        )
    }

    /// A non-positive budget must not produce a negative offset, which would trap
    /// in `seek(toOffset:)`.
    func testNonPositiveBudgetIsSafe() {
        XCTAssertEqual(ProviderQuotaSnapshotLog.readStartOffset(fileSize: 5_000, budgetBytes: 0), 0)
        XCTAssertEqual(ProviderQuotaSnapshotLog.readStartOffset(fileSize: 5_000, budgetBytes: -10), 0)
    }

    // MARK: - Line alignment

    /// Reading from the middle of a file lands inside a record. The leading
    /// fragment must be dropped or the parser sees half a JSON object.
    func testLeadingPartialLineIsDropped() {
        let data = Data("\"partial\":tru".utf8) + Data("\n{\"ok\":1}\n".utf8)
        let aligned = ProviderQuotaSnapshotLog.alignedTail(data, startedMidFile: true)

        XCTAssertEqual(String(data: aligned, encoding: .utf8), "{\"ok\":1}\n")
    }

    /// When the read started at the beginning of the file, the first line is
    /// whole and must be kept.
    func testFirstLineIsKeptWhenReadFromStart() {
        let data = Data("{\"ok\":1}\n{\"ok\":2}\n".utf8)
        let aligned = ProviderQuotaSnapshotLog.alignedTail(data, startedMidFile: false)

        XCTAssertEqual(String(data: aligned, encoding: .utf8), "{\"ok\":1}\n{\"ok\":2}\n")
    }

    /// A tail with no newline at all is one partial record; dropping it is
    /// correct, and keeping it would hand a truncated object to the parser.
    func testTailWithoutNewlineYieldsNothing() {
        let aligned = ProviderQuotaSnapshotLog.alignedTail(Data("{\"partial\":".utf8), startedMidFile: true)
        XCTAssertTrue(aligned.isEmpty)
    }

    // MARK: - Rotation bounds

    /// Rotation must keep enough history that a subsequent bounded read still
    /// sees the full consumption window.
    func testKeptBytesCoverTheReadBudget() {
        XCTAssertGreaterThanOrEqual(
            ProviderQuotaSnapshotLog.keepBytes,
            ProviderQuotaSnapshotLog.readBudgetBytes,
            "after a rotation the retained tail must still satisfy a full read budget"
        )
    }

    func testMaxBytesIsAboveKeepBytes() {
        XCTAssertGreaterThan(ProviderQuotaSnapshotLog.maxBytes, ProviderQuotaSnapshotLog.keepBytes)
    }
}
