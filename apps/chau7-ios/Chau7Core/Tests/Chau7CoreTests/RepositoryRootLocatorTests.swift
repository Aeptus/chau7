import Foundation
import XCTest
@testable import Chau7Core

final class RepositoryRootLocatorTests: XCTestCase {
    func testRepositoryDirectoryAndGitFileWorktreeLookup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("nested/deep")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let marker = root.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: true)
        XCTAssertEqual(RepositoryRootLocator.repositoryRoot(startingAt: nested.path), root.path)
        try FileManager.default.removeItem(at: marker)
        try Data("gitdir: ../actual-git\n".utf8).write(to: marker)
        XCTAssertEqual(RepositoryRootLocator.repositoryRoot(startingAt: nested.path), root.path)
    }

    func testFileStartsAtParentAndNoRepositoryReturnsNil() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file")
        try Data().write(to: file)
        XCTAssertNil(RepositoryRootLocator.repositoryRoot(startingAt: file.path))
        try Data().write(to: root.appendingPathComponent(".git"))
        XCTAssertEqual(RepositoryRootLocator.repositoryRoot(startingAt: file.path), root.path)
        XCTAssertNil(RepositoryRootLocator.repositoryRoot(startingAt: "  "))
    }
}
