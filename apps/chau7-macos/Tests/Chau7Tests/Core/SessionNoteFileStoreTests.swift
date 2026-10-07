import Foundation
import XCTest
@testable import Chau7Core

final class SessionNoteFileStoreTests: XCTestCase {
    func testPreparationPreservesExistingContents() throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let tab = UUID()
        let path = try XCTUnwrap(SessionNoteFileStore.prepare(repoRoot: root.path, tabID: tab))
        try "existing note".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(SessionNoteFileStore.prepare(repoRoot: root.path, tabID: tab), path)
        XCTAssertEqual(SessionNoteFileStore.existing(repoRoot: root.path, tabID: tab), path)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "existing note")
    }

    func testGitWorktreeMarkerFileIsAccepted() throws {
        let root = try makeRepository(worktree: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(SessionNoteFileStore.isRepositoryRoot(root.path))
        XCTAssertNotNil(SessionNoteFileStore.prepare(repoRoot: root.path, tabID: UUID()))
    }

    func testNonRepositoryIsNotModified() throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: root.appendingPathComponent(".git"))
        XCTAssertFalse(SessionNoteFileStore.isRepositoryRoot(root.path))
        XCTAssertNil(SessionNoteFileStore.prepare(repoRoot: root.path, tabID: UUID()))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testDeletionAfterValidationCannotRecreateRoot() throws {
        let root = try makeRepository()
        let result = SessionNoteFileStore.prepare(repoRoot: root.path, tabID: UUID()) {
            do { try FileManager.default.removeItem(at: root) } catch { XCTFail("fixture deletion failed: \(error)") }
        }
        XCTAssertNil(result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testReplacementAfterValidationCannotWriteIntoNewRoot() throws {
        let root = try makeRepository()
        let moved = root.appendingPathExtension("moved")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: moved)
        }
        let result = SessionNoteFileStore.prepare(repoRoot: root.path, tabID: UUID()) {
            do {
                try FileManager.default.moveItem(at: root, to: moved)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
                try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: false)
            } catch { XCTFail("fixture replacement failed: \(error)") }
        }
        XCTAssertNil(result, "A reused path is not the repository we opened")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".chau7").path))
    }

    func testMovedCachedRootIsNotRecreated() throws {
        let root = try makeRepository()
        let moved = root.appendingPathExtension("moved")
        try FileManager.default.moveItem(at: root, to: moved)
        defer { try? FileManager.default.removeItem(at: moved) }
        XCTAssertNil(SessionNoteFileStore.prepare(repoRoot: root.path, tabID: UUID()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertNotNil(SessionNoteFileStore.prepare(repoRoot: moved.path, tabID: UUID()))
    }

    func testSymlinkAtEveryOwnedComponentIsRejected() throws {
        for position in 0 ..< 4 {
            let root = try makeRepository()
            let outside = try makeRepository()
            defer {
                try? FileManager.default.removeItem(at: root)
                try? FileManager.default.removeItem(at: outside)
            }
            let tab = UUID()
            let components = [".chau7", "sessions", tab.uuidString.lowercased(), "note.md"]
            var parent = root
            for component in components.prefix(position) {
                parent.appendPathComponent(component)
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            }
            let target = outside.appendingPathComponent("target")
            if position == 3 {
                try "outside content".write(to: target, atomically: true, encoding: .utf8)
            } else {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            }
            try FileManager.default.createSymbolicLink(
                at: parent.appendingPathComponent(components[position]), withDestinationURL: target
            )
            XCTAssertNil(SessionNoteFileStore.prepare(repoRoot: root.path, tabID: tab), "component \(position)")
            XCTAssertNil(SessionNoteFileStore.existing(repoRoot: root.path, tabID: tab))
            if position == 3 {
                XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "outside content")
            } else {
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
            }
        }
    }

    func testCreationObstructionReturnsUnavailable() throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        try "not a directory".write(to: root.appendingPathComponent(".chau7"), atomically: true, encoding: .utf8)
        XCTAssertNil(SessionNoteFileStore.prepare(repoRoot: root.path, tabID: UUID()))
    }

    func testRestorationRejectsDirectoryInsteadOfNoteFile() throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let tab = UUID()
        let path = SessionNoteAttachmentLocator.filePath(repoRoot: root.path, tabID: tab)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        XCTAssertNil(SessionNoteFileStore.existing(repoRoot: root.path, tabID: tab))
        XCTAssertNil(SessionNoteFileStore.prepare(repoRoot: root.path, tabID: tab))
    }

    func testRemovedGitIdentityMakesExistingNoteUnavailable() throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let tab = UUID()
        XCTAssertNotNil(SessionNoteFileStore.prepare(repoRoot: root.path, tabID: tab))
        try FileManager.default.removeItem(at: root.appendingPathComponent(".git"))
        XCTAssertNil(SessionNoteFileStore.existing(repoRoot: root.path, tabID: tab))
    }

    private func makeRepository(worktree: Bool = false) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("note-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let git = root.appendingPathComponent(".git")
        if worktree {
            try "gitdir: /existing/git/worktrees/example\n".write(to: git, atomically: true, encoding: .utf8)
        } else {
            try FileManager.default.createDirectory(at: git, withIntermediateDirectories: false)
        }
        return root
    }
}
