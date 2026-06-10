import XCTest
@testable import Chau7
@testable import Chau7Core

/// Direct tests for the extracted SessionNoteCoordinator. The end-to-end
/// behavior is covered by AttachedSessionNoteTests through the controller;
/// these tests pin the coordinator's surface — path math, disk-existence
/// checks, idempotent prepare — without the controller in the picture.
final class SessionNoteCoordinatorTests: XCTestCase {

    func testAttachedNotePathDerivesFromTabIDAndRepoRoot() {
        let tabID = UUID()
        // Use a real on-disk dir; the locator standardizes paths so /tmp
        // becomes /private/tmp on macOS, which would break a hasPrefix
        // check against a hand-rolled string.
        let repoRoot = makeTemporaryDirectory(prefix: "coord-derive")
        defer { try? FileManager.default.removeItem(atPath: repoRoot) }
        let coord = SessionNoteCoordinator(tabID: tabID, repoRoot: repoRoot)

        XCTAssertTrue(coord.attachedNotePath.contains("/.chau7/sessions/"))
        // The locator lowercases the tabID segment; assert on that form.
        XCTAssertTrue(coord.attachedNotePath.contains(tabID.uuidString.lowercased()))
        XCTAssertTrue(coord.attachedNotePath.hasSuffix("/note.md"))
    }

    func testExistingNotePathReturnsNilUntilFilePresent() {
        let repoRoot = makeTemporaryDirectory(prefix: "coord-existing")
        defer { try? FileManager.default.removeItem(atPath: repoRoot) }
        let coord = SessionNoteCoordinator(tabID: UUID(), repoRoot: repoRoot)

        XCTAssertNil(coord.existingNotePath, "No file yet — must be nil")
        _ = coord.prepareNoteFile()
        XCTAssertEqual(coord.existingNotePath, coord.attachedNotePath)
    }

    func testPrepareNoteFileCreatesEmptyFileIdempotently() throws {
        let repoRoot = makeTemporaryDirectory(prefix: "coord-prepare")
        defer { try? FileManager.default.removeItem(atPath: repoRoot) }
        let coord = SessionNoteCoordinator(tabID: UUID(), repoRoot: repoRoot)

        let path1 = coord.prepareNoteFile()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path1))
        XCTAssertEqual(try String(contentsOfFile: path1, encoding: .utf8), "")

        // Write some content directly — a second prepare() must not stomp it.
        try "user-written content\n".write(toFile: path1, atomically: true, encoding: .utf8)

        let path2 = coord.prepareNoteFile()
        XCTAssertEqual(path1, path2)
        XCTAssertEqual(
            try String(contentsOfFile: path2, encoding: .utf8),
            "user-written content\n",
            "prepareNoteFile is idempotent — it must not overwrite existing content"
        )
    }

    func testPrepareCreatesParentDirectory() {
        // The .chau7/sessions/<id> directory does not exist yet — prepare
        // must create it before writing the empty file.
        let repoRoot = makeTemporaryDirectory(prefix: "coord-mkdir")
        defer { try? FileManager.default.removeItem(atPath: repoRoot) }
        let coord = SessionNoteCoordinator(tabID: UUID(), repoRoot: repoRoot)

        let chau7Dir = URL(fileURLWithPath: repoRoot).appendingPathComponent(".chau7").path
        XCTAssertFalse(FileManager.default.fileExists(atPath: chau7Dir), "precondition")

        _ = coord.prepareNoteFile()
        XCTAssertTrue(FileManager.default.fileExists(atPath: chau7Dir))
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory(prefix: String) -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }
}
