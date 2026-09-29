import Foundation
import Chau7Core

protocol PerformanceTelemetryRecording: AnyObject {
    func record(category: String, fields: [String: Any], at date: Date)
}

/// Dedicated bounded JSONL sink for sampled performance aggregates. Routine
/// measurements no longer consume the operational Chau7.log rotation budget;
/// that log remains reserved for lifecycle transitions and actionable faults.
///
/// `@unchecked Sendable` is asserted against `queue`, verified rather than
/// assumed: `fileHandle` and `didReportWriteFailure` are the only mutable
/// fields, and every read and write of both happens inside `write(_:)`, which
/// is reached only from the `queue.async` block in `record(category:fields:at:)`.
/// `openIfNeeded` and `rotateIfNeeded` are `private` and called from nowhere
/// else, so no caller can touch the handle off-queue.
final class PerformanceTelemetryWriter: PerformanceTelemetryRecording, @unchecked Sendable {
    static let shared = PerformanceTelemetryWriter()

    private let fileURL: URL
    private let archiveURL: URL
    private let maxBytes: Int
    private let queue: DispatchQueue
    private var fileHandle: FileHandle?
    private var didReportWriteFailure = false

    init(
        fileURL: URL = RuntimeIsolation.logsDirectory()
            .appendingPathComponent("Chau7-performance.jsonl"),
        maxBytes: Int = 8 * 1024 * 1024,
        queueLabel: String = "com.chau7.performance-telemetry"
    ) {
        self.fileURL = fileURL
        self.archiveURL = fileURL.deletingPathExtension()
            .appendingPathExtension("jsonl.1")
        self.maxBytes = max(1, maxBytes)
        self.queue = DispatchQueue(label: queueLabel, qos: .utility)
    }

    func record(category: String, fields: [String: Any], at date: Date = Date()) {
        let envelope: [String: Any] = [
            "schema_version": 1,
            "timestamp": DateFormatters.iso8601.string(from: date),
            "category": category,
            "metrics": fields
        ]
        guard JSONSerialization.isValidJSONObject(envelope),
              var data = try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]) else {
            return
        }
        data.append(0x0A)
        // Bound before the hand-off: `data` is a `var` above, and capturing a
        // mutable local in the escaping closure is what the compiler flags.
        // Freezing it to a `let` makes the capture genuinely immutable.
        let payload = data
        queue.async { [self] in
            write(payload)
        }
    }

    /// Deterministic drain seam for tests and orderly shutdown diagnostics.
    func flush() {
        queue.sync {}
    }

    var archiveURLForTesting: URL {
        archiveURL
    }

    private func write(_ data: Data) {
        do {
            try openIfNeeded()
            try rotateIfNeeded(incomingBytes: data.count)
            try openIfNeeded()
            try fileHandle?.write(contentsOf: data)
            didReportWriteFailure = false
        } catch {
            guard !didReportWriteFailure else { return }
            didReportWriteFailure = true
            Log.warn("PerformanceTelemetry: write unavailable; sampled metrics will be dropped until recovery")
        }
    }

    private func openIfNeeded() throws {
        guard fileHandle == nil else { return }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            _ = FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        fileHandle = handle
    }

    private func rotateIfNeeded(incomingBytes: Int) throws {
        let currentBytes = ((try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size]) as? NSNumber)?.intValue ?? 0
        guard currentBytes > 0, currentBytes + incomingBytes > maxBytes else { return }

        try fileHandle?.close()
        fileHandle = nil
        if FileManager.default.fileExists(atPath: archiveURL.path) {
            try FileManager.default.removeItem(at: archiveURL)
        }
        try FileManager.default.moveItem(at: fileURL, to: archiveURL)
    }
}
