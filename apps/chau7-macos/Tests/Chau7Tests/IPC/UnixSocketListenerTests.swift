import XCTest
@testable import Chau7

final class UnixSocketListenerTests: XCTestCase {
    private var listener: UnixSocketListener?

    override func tearDown() {
        listener?.stop(removeSocketFile: true)
        listener = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// `sun_path` caps socket paths at ~104 bytes, so keep names short.
    private func makeSocketPath() -> String {
        let name = "usl-\(UUID().uuidString.prefix(8)).sock"
        return (NSTemporaryDirectory() as NSString).appendingPathComponent(name)
    }

    /// Connects a client to `path`; returns the descriptor, or -1 on failure.
    private func connectClient(to path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }

        var addr = UnixSocketListener.makeAddress(path: path)
        let result = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard result == 0 else {
            close(fd)
            return -1
        }
        return fd
    }

    // MARK: - Tests

    func testBindAndAcceptRoundTrip() throws {
        let path = makeSocketPath()
        let queue = DispatchQueue(label: "test.usl.roundtrip")
        let accepted = expectation(description: "accepted a client connection")
        let acceptedFDLock = NSLock()
        var acceptedFD: Int32 = -1

        let listener = UnixSocketListener(path: path, queue: queue)
        self.listener = listener
        try listener.start(
            backlog: 1,
            onAccept: { fd in
                acceptedFDLock.lock()
                acceptedFD = fd
                acceptedFDLock.unlock()
                accepted.fulfill()
            },
            onAcceptFailure: { acceptErrno in
                XCTFail("accept failed unexpectedly: \(String(cString: strerror(acceptErrno)))")
            }
        )
        XCTAssertTrue(listener.isAccepting)

        let clientFD = connectClient(to: path)
        XCTAssertGreaterThanOrEqual(clientFD, 0, "client connect should succeed")
        defer { close(clientFD) }

        wait(for: [accepted], timeout: 5)

        acceptedFDLock.lock()
        let serverFD = acceptedFD
        acceptedFDLock.unlock()
        XCTAssertGreaterThanOrEqual(serverFD, 0)
        defer { close(serverFD) }

        // Round-trip a byte through the accepted connection.
        var sent: UInt8 = 0x42
        XCTAssertEqual(write(clientFD, &sent, 1), 1)
        var received: UInt8 = 0
        XCTAssertEqual(read(serverFD, &received, 1), 1)
        XCTAssertEqual(received, sent)
    }

    func testRemoveStaleSocketFileAllowsRebinding() throws {
        let path = makeSocketPath()
        // Simulate a stale socket file left behind by a crashed process.
        // Binding over an existing path fails, so removal must happen first.
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: nil))

        let listener = UnixSocketListener(path: path, queue: DispatchQueue(label: "test.usl.stale"))
        self.listener = listener
        listener.removeStaleSocketFile()
        try listener.start(
            backlog: 1,
            onAccept: { close($0) },
            onAcceptFailure: { _ in }
        )

        let clientFD = connectClient(to: path)
        XCTAssertGreaterThanOrEqual(clientFD, 0, "listener should accept connections after replacing the stale file")
        close(clientFD)
    }

    func testRemoveStaleSocketFileIfInactiveRefusesLiveSocket() throws {
        let path = makeSocketPath()
        let active = UnixSocketListener(path: path, queue: DispatchQueue(label: "test.usl.active"))
        listener = active
        try active.start(
            backlog: 1,
            onAccept: { close($0) },
            onAcceptFailure: { _ in }
        )

        let rival = UnixSocketListener(path: path, queue: DispatchQueue(label: "test.usl.rival"))
        XCTAssertFalse(rival.removeStaleSocketFileIfInactive(), "must refuse to remove a socket another listener is serving")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        active.stop(removeSocketFile: true)
        listener = nil
        XCTAssertTrue(rival.removeStaleSocketFileIfInactive(), "a dead socket path should be reclaimable")
    }

    func testStopClosesListener() throws {
        let path = makeSocketPath()
        let listener = UnixSocketListener(path: path, queue: DispatchQueue(label: "test.usl.stop"))
        self.listener = listener
        try listener.start(
            backlog: 1,
            onAccept: { close($0) },
            onAcceptFailure: { _ in }
        )

        let firstFD = connectClient(to: path)
        XCTAssertGreaterThanOrEqual(firstFD, 0)
        close(firstFD)

        listener.stop(removeSocketFile: true)

        XCTAssertFalse(listener.isAccepting)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(connectClient(to: path), -1, "connect after stop() should fail")
    }

    func testConcurrentConnectionsSmoke() throws {
        let path = makeSocketPath()
        let clientCount = 8
        let accepted = expectation(description: "accepted all concurrent clients")
        accepted.expectedFulfillmentCount = clientCount

        let listener = UnixSocketListener(path: path, queue: DispatchQueue(label: "test.usl.concurrent"))
        self.listener = listener
        try listener.start(
            backlog: 16,
            onAccept: { fd in
                close(fd)
                accepted.fulfill()
            },
            onAcceptFailure: { acceptErrno in
                XCTFail("accept failed unexpectedly: \(String(cString: strerror(acceptErrno)))")
            }
        )

        let clientFDsLock = NSLock()
        var clientFDs: [Int32] = []
        DispatchQueue.concurrentPerform(iterations: clientCount) { _ in
            let fd = connectClient(to: path)
            XCTAssertGreaterThanOrEqual(fd, 0, "concurrent client connect should succeed")
            clientFDsLock.lock()
            clientFDs.append(fd)
            clientFDsLock.unlock()
        }

        wait(for: [accepted], timeout: 5)

        clientFDsLock.lock()
        let openFDs = clientFDs
        clientFDsLock.unlock()
        for fd in openFDs where fd >= 0 {
            close(fd)
        }
    }
}
