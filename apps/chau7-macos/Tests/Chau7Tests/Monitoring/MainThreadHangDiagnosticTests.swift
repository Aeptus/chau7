import Foundation
import XCTest
@testable import Chau7

final class MainThreadHangDiagnosticTests: XCTestCase {
    func testRetentionKeepsRecentBundlesTogetherAndIgnoresHeartbeat() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        for index in 0 ..< 45 {
            for suffix in [".json", ".sample.txt"] {
                let url = directory.appendingPathComponent("hang-\(index)-pid-123" + suffix)
                try Data("sample".utf8).write(to: url)
                try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-Double(index))], ofItemAtPath: url.path)
            }
        }
        let heartbeat = directory.appendingPathComponent("main-thread-heartbeat.json")
        try Data("heartbeat".utf8).write(to: heartbeat)
        MainThreadHangWatchdogRunner.pruneDiagnostics(in: directory, now: now)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names.filter { $0.hasPrefix("hang-") }.count, 80)
        XCTAssertTrue(names.contains(heartbeat.lastPathComponent))
        for index in 0 ..< 45 {
            XCTAssertEqual(names.contains("hang-\(index)-pid-123.json"), index < 40)
            XCTAssertEqual(names.contains("hang-\(index)-pid-123.sample.txt"), index < 40)
        }
    }

    func testOversizedAndExpiredDiagnosticsArePrunedWithoutRemovingLatestManifest() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        let old = directory.appendingPathComponent("hang-old-pid-123.json")
        try Data("old".utf8).write(to: old)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-8 * 86400)], ofItemAtPath: old.path)
        let oversized = directory.appendingPathComponent("hang-huge-pid-123.sample.txt")
        try Data().write(to: oversized)
        let file = try FileHandle(forWritingTo: oversized)
        try file.truncate(atOffset: 9 * 1024 * 1024)
        try file.close()
        let latest = directory.appendingPathComponent("latest-hang.json")
        try Data("latest".utf8).write(to: latest)
        MainThreadHangWatchdogRunner.pruneDiagnostics(in: directory, now: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oversized.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: latest.path))
    }
}
