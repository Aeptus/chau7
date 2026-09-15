import AppKit
import Chau7Core
import Darwin
import Foundation

/// Holds a non-blocking advisory lock for the lifetime of the application.
///
/// The lock file is intentionally retained after shutdown. `flock` ownership is
/// attached to the open descriptor, so a retained file avoids an unlink/recreate
/// race while still allowing the next process to acquire it immediately.
final class ApplicationInstanceLock {
    struct Owner: Codable, Equatable {
        let pid: Int32
        let launchToken: UUID
        let acquiredAt: Date
    }

    enum AcquisitionResult: Equatable {
        case acquired(Owner)
        case alreadyRunning(Owner?)
        case failed(errno: Int32)
    }

    static let shared = ApplicationInstanceLock(
        lockFileURL: RuntimeIsolation.appSupportDirectory(named: "Chau7")
            .appendingPathComponent("app-instance.lock"),
        owner: Owner(
            pid: ProcessInfo.processInfo.processIdentifier,
            launchToken: UUID(),
            acquiredAt: Date()
        )
    )

    let owner: Owner
    private let lockFileURL: URL
    private var fileDescriptor: Int32 = -1

    init(lockFileURL: URL, owner: Owner) {
        self.lockFileURL = lockFileURL
        self.owner = owner
    }

    deinit {
        release()
    }

    func acquire() -> AcquisitionResult {
        if fileDescriptor >= 0 {
            return .acquired(owner)
        }

        do {
            try FileManager.default.createDirectory(
                at: lockFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            Log.error("ApplicationInstanceLock: failed to create lock directory: \(error)")
            return .failed(errno: EIO)
        }

        let fd = open(lockFileURL.path, O_RDWR | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return .failed(errno: errno) }

        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let lockErrno = errno
            let existingOwner = Self.readOwner(from: fd)
            close(fd)
            if lockErrno == EWOULDBLOCK {
                return .alreadyRunning(existingOwner)
            }
            return .failed(errno: lockErrno)
        }

        guard Self.writeOwner(owner, to: fd) else {
            let writeErrno = errno == 0 ? EIO : errno
            flock(fd, LOCK_UN)
            close(fd)
            return .failed(errno: writeErrno)
        }

        fileDescriptor = fd
        return .acquired(owner)
    }

    func activateExistingApplication(owner: Owner?) {
        guard let owner,
              let application = NSRunningApplication(processIdentifier: owner.pid) else {
            return
        }
        application.activate(options: [.activateAllWindows])
    }

    func release() {
        guard fileDescriptor >= 0 else { return }
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
        fileDescriptor = -1
    }

    private static func readOwner(from fd: Int32) -> Owner? {
        guard lseek(fd, 0, SEEK_SET) >= 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &bytes, bytes.count)
        guard count > 0 else { return nil }
        return try? JSONDecoder().decode(Owner.self, from: Data(bytes.prefix(Int(count))))
    }

    private static func writeOwner(_ owner: Owner, to fd: Int32) -> Bool {
        guard let data = try? JSONEncoder().encode(owner),
              ftruncate(fd, 0) == 0,
              lseek(fd, 0, SEEK_SET) >= 0 else {
            return false
        }
        return data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return false }
            return write(fd, baseAddress, buffer.count) == buffer.count
        }
    }
}
