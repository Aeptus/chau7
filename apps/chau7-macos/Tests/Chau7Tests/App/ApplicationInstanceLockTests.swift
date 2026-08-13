import XCTest
@testable import Chau7

final class ApplicationInstanceLockTests: XCTestCase {
    func testSecondOwnerIsRefusedUntilFirstReleasesLock() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chau7-instance-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockURL = directory.appendingPathComponent("instance.lock")
        let firstOwner = ApplicationInstanceLock.Owner(pid: 101, launchToken: UUID(), acquiredAt: Date())
        let secondOwner = ApplicationInstanceLock.Owner(pid: 202, launchToken: UUID(), acquiredAt: Date())
        let first = ApplicationInstanceLock(lockFileURL: lockURL, owner: firstOwner)
        let second = ApplicationInstanceLock(lockFileURL: lockURL, owner: secondOwner)

        XCTAssertEqual(first.acquire(), .acquired(firstOwner))
        XCTAssertEqual(second.acquire(), .alreadyRunning(firstOwner))

        first.release()
        XCTAssertEqual(second.acquire(), .acquired(secondOwner))
    }
}
