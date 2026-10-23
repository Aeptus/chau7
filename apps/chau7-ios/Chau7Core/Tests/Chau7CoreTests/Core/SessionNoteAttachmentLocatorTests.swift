import XCTest
@testable import Chau7Core

final class SessionNoteAttachmentLocatorTests: XCTestCase {

    func testFilePathUsesRepoRootAndTabID() {
        let tabID = UUID(uuidString: "AABBCCDD-1234-5678-9012-AABBCCDDEEFF")!
        let path = SessionNoteAttachmentLocator.filePath(
            repoRoot: "/tmp/example-repo",
            tabID: tabID
        )

        XCTAssertEqual(
            path,
            "/tmp/example-repo/.chau7/sessions/aabbccdd-1234-5678-9012-aabbccddeeff/note.md"
        )
    }

    func testIsSessionNotePathRecognizesExpectedLocation() {
        XCTAssertTrue(
            SessionNoteAttachmentLocator.isSessionNotePath(
                "/tmp/example/.chau7/sessions/aabbccdd-1234-5678-9012-aabbccddeeff/note.md"
            )
        )
        XCTAssertFalse(SessionNoteAttachmentLocator.isSessionNotePath("/tmp/example/.chau7/plan.md"))
        XCTAssertFalse(SessionNoteAttachmentLocator.isSessionNotePath("/tmp/example/notes/note.md"))
    }
}
