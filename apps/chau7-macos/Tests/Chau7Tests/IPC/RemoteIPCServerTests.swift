import XCTest
@testable import Chau7

final class RemoteIPCServerTests: XCTestCase {
    func testStartCreatesOwnerOnlySocketAndDirectory() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ripc-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let socketURL = directory.appendingPathComponent("remote.sock")
        let server = RemoteIPCServer(socketPath: socketURL)
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: directory)
        }

        server.start()

        var socketInfo = stat()
        guard lstat(socketURL.path, &socketInfo) == 0 else {
            XCTFail("Remote IPC socket should be created")
            return
        }
        XCTAssertEqual(socketInfo.st_mode & 0o777, 0o600)

        var directoryInfo = stat()
        guard lstat(directory.path, &directoryInfo) == 0 else {
            XCTFail("Remote IPC socket directory should be created")
            return
        }
        XCTAssertEqual(directoryInfo.st_mode & 0o777, 0o700)
    }

    func testStartRestrictsExistingSocketDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ripc-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        let socketURL = directory.appendingPathComponent("remote.sock")
        let server = RemoteIPCServer(socketPath: socketURL)
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: directory)
        }

        server.start()

        var socketInfo = stat()
        guard lstat(socketURL.path, &socketInfo) == 0 else {
            XCTFail("Remote IPC socket should be created")
            return
        }
        XCTAssertEqual(socketInfo.st_mode & 0o777, 0o600)

        var directoryInfo = stat()
        guard lstat(directory.path, &directoryInfo) == 0 else {
            XCTFail("Remote IPC socket directory should exist")
            return
        }
        XCTAssertEqual(directoryInfo.st_mode & 0o777, 0o700)
    }
}
