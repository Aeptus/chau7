import XCTest
@testable import Chau7Core

final class PermissionDenialClassifierTests: XCTestCase {
    private let roots = ["/Users/me/Downloads", "/Users/me/Desktop"]

    func testEpermInProtectedCwdIsFlagged() {
        let v = PermissionDenialClassifier.classify(
            output: "Error: Operation not permitted (os error 1)",
            cwd: "/Users/me/Downloads/Repositories/wiki-polis",
            protectedRoots: roots
        )
        XCTAssertTrue(v.isFullDiskAccessDenial)
        XCTAssertEqual(v.protectedRoot, "/Users/me/Downloads")
    }

    func testRustOsError1IsRecognized() {
        let v = PermissionDenialClassifier.classify(
            output: "thread 'main' panicked: os error 1",
            cwd: "/Users/me/Desktop/proj",
            protectedRoots: roots
        )
        XCTAssertTrue(v.isFullDiskAccessDenial)
        XCTAssertEqual(v.protectedRoot, "/Users/me/Desktop")
    }

    func testEpermOutsideProtectedCwdIsNotFlagged() {
        let v = PermissionDenialClassifier.classify(
            output: "Operation not permitted",
            cwd: "/Users/me/code/proj",
            protectedRoots: roots
        )
        XCTAssertFalse(v.isFullDiskAccessDenial)
        XCTAssertNil(v.protectedRoot)
    }

    func testProtectedCwdWithoutMarkerIsNotFlagged() {
        let v = PermissionDenialClassifier.classify(
            output: "build succeeded",
            cwd: "/Users/me/Downloads/x",
            protectedRoots: roots
        )
        XCTAssertFalse(v.isFullDiskAccessDenial)
    }

    func testSiblingDirectoryIsNotConsideredUnderRoot() {
        // "/Users/me/Downloads2" must not match root "/Users/me/Downloads".
        XCTAssertNil(PermissionDenialClassifier.protectedRoot(
            for: "/Users/me/Downloads2/x", in: roots
        ))
    }

    func testRootItselfMatches() {
        XCTAssertEqual(
            PermissionDenialClassifier.protectedRoot(for: "/Users/me/Downloads", in: roots),
            "/Users/me/Downloads"
        )
    }

    func testTrailingSlashesNormalized() {
        XCTAssertEqual(
            PermissionDenialClassifier.protectedRoot(
                for: "/Users/me/Downloads/", in: ["/Users/me/Downloads///"]
            ),
            "/Users/me/Downloads///"
        )
    }

    func testCaseInsensitiveMarker() {
        let v = PermissionDenialClassifier.classify(
            output: "EPERM: operation failed",
            cwd: "/Users/me/Downloads/x",
            protectedRoots: roots
        )
        XCTAssertTrue(v.isFullDiskAccessDenial)
    }
}
