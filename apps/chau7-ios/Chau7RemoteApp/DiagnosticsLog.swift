import Foundation
import Observation
import UIKit
import os

/// In-app verbose diagnostics log shipped to *all* users.
///
/// Captures structured events, performance samples, and (optionally) every
/// keystroke entered in the app into a bounded ring buffer that is also
/// persisted to disk so it survives relaunches. The whole buffer can be
/// exported as a single plain-text file for support and investigation.
///
/// Privacy: everything stays on-device. Nothing here is uploaded; the log
/// only leaves the device when the user explicitly taps Export and chooses a
/// destination. Keystroke capture is gated behind a setting and a clear
/// in-UI disclosure because it records the literal characters typed.
@MainActor
@Observable
final class DiagnosticsLog {
    static let shared = DiagnosticsLog()

    enum Level: Int, Comparable, CustomStringConvertible {
        case trace, debug, info, warn, error

        static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }

        var description: String {
            switch self {
            case .trace: return "TRACE"
            case .debug: return "DEBUG"
            case .info: return "INFO"
            case .warn: return "WARN"
            case .error: return "ERROR"
            }
        }
    }

    enum Category: String, CaseIterable {
        case lifecycle
        case connection
        case input
        case keystroke
        case performance
        case tab
        case approval
        case render
        case ui
        case network
    }

    struct Entry: Identifiable, Codable, Sendable {
        let id: UInt64
        let timestamp: Date
        let level: Int
        let category: String
        let message: String
        let metadata: [String: String]

        var levelValue: Level { Level(rawValue: level) ?? .info }
    }

    // MARK: - Stored state

    /// Newest-last ring buffer of recorded entries. Observed so the in-app
    /// viewer updates live.
    private(set) var entries: [Entry] = []

    /// Total number of entries ever recorded this install (including ones
    /// already evicted from the ring buffer). Useful context in exports.
    private(set) var totalRecorded: UInt64 = 0

    private var nextID: UInt64 = 1
    private var saveTask: Task<Void, Never>?
    /// All persistence runs on this serial queue so writes can never reorder:
    /// a debounced autosave and a synchronous background flush are strictly
    /// ordered, and an older snapshot can never overwrite a newer one.
    private let saveQueue = DispatchQueue(label: "ch7.diagnostics.save", qos: .utility)

    private let osLog = Logger(subsystem: "ch7", category: "Diagnostics")

    /// Hard cap on retained entries. Performance + keystroke logging is high
    /// volume, so the cap is generous but bounded to protect memory/disk.
    private static let maxEntries = 8000
    /// How many leading entries are already on disk (incremental-append cursor).
    private var persistedEntryCount = 0
    /// Set when the ring trimmed (or state was reloaded/cleared) — the next
    /// save must rewrite the whole file instead of appending.
    private var needsFullRewrite = false
    private static let fileName = "diagnostics.jsonl"

    private var fileURL: URL? {
        let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base?.appendingPathComponent(Self.fileName)
    }

    // MARK: - Init

    private init() {
        load()
        record(.info, .lifecycle, "Diagnostics log initialized", [
            "retained": String(entries.count),
            "device": UIDevice.current.model,
            "os": UIDevice.current.systemVersion,
            "app_version": RemoteClient.appVersion
        ])
    }

    // MARK: - Settings

    var isKeystrokeLoggingEnabled: Bool {
        UserDefaults.standard.object(forKey: AppSettings.logKeystrokesKey) as? Bool
            ?? AppSettings.logKeystrokesDefault
    }

    var isVerboseLoggingEnabled: Bool {
        UserDefaults.standard.object(forKey: AppSettings.verboseLoggingKey) as? Bool
            ?? AppSettings.verboseLoggingDefault
    }

    // MARK: - Recording

    /// Core entry point. All convenience helpers funnel through here.
    /// `force` keeps an entry regardless of the verbose-logging gate (used by
    /// keystroke capture, which has its own dedicated toggle).
    func record(
        _ level: Level,
        _ category: Category,
        _ message: String,
        _ metadata: [String: String] = [:],
        force: Bool = false
    ) {
        // Trace/debug noise is dropped unless verbose logging is enabled, but
        // info and above are always retained so the export is useful by default.
        if level < .info, !isVerboseLoggingEnabled, !force { return }

        let entry = Entry(
            id: nextID,
            timestamp: Date(),
            level: level.rawValue,
            category: category.rawValue,
            message: message,
            metadata: metadata
        )
        nextID += 1
        totalRecorded += 1

        entries.append(entry)
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
            needsFullRewrite = true
            persistedEntryCount = 0
        }

        mirrorToOSLog(entry)
        scheduleSave()
    }

    func trace(_ category: Category, _ message: String, _ metadata: [String: String] = [:]) {
        record(.trace, category, message, metadata)
    }

    func debug(_ category: Category, _ message: String, _ metadata: [String: String] = [:]) {
        record(.debug, category, message, metadata)
    }

    func info(_ category: Category, _ message: String, _ metadata: [String: String] = [:]) {
        record(.info, category, message, metadata)
    }

    func warn(_ category: Category, _ message: String, _ metadata: [String: String] = [:]) {
        record(.warn, category, message, metadata)
    }

    func error(_ category: Category, _ message: String, _ metadata: [String: String] = [:]) {
        record(.error, category, message, metadata)
    }

    /// Record a keystroke. No-op when keystroke logging is disabled. `value`
    /// is the human-readable representation of what was typed (a character,
    /// a control-key label like "^C", or "<return>").
    func keystroke(_ value: String, field: String, extra: [String: String] = [:]) {
        guard isKeystrokeLoggingEnabled else { return }
        var metadata = extra
        metadata["field"] = field
        metadata["chars"] = String(value.count)
        record(.debug, .keystroke, Self.describeKeystroke(value), metadata, force: true)
    }

    // MARK: - Performance

    /// Record a single performance measurement (in milliseconds).
    func performance(_ name: String, durationMs: Double, _ metadata: [String: String] = [:]) {
        var meta = metadata
        meta["duration_ms"] = String(format: "%.2f", durationMs)
        if let footprint = Self.memoryFootprintBytes() {
            meta["mem_mb"] = String(format: "%.1f", Double(footprint) / 1_048_576)
        }
        record(.info, .performance, name, meta)
    }

    /// Measure the duration of a synchronous block and record it.
    @discardableResult
    func measure<T>(_ name: String, _ metadata: [String: String] = [:], _ body: () throws -> T) rethrows -> T {
        let start = DispatchTime.now()
        let result = try body()
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        performance(name, durationMs: elapsedMs, metadata)
        return result
    }

    /// Capture a point-in-time performance snapshot (memory, thermal, uptime).
    func capturePerformanceSnapshot(reason: String) {
        var meta: [String: String] = ["reason": reason]
        if let footprint = Self.memoryFootprintBytes() {
            meta["mem_mb"] = String(format: "%.1f", Double(footprint) / 1_048_576)
        }
        meta["physical_mem_mb"] = String(ProcessInfo.processInfo.physicalMemory / 1_048_576)
        meta["thermal"] = Self.thermalStateDescription(ProcessInfo.processInfo.thermalState)
        meta["uptime_s"] = String(format: "%.0f", ProcessInfo.processInfo.systemUptime)
        meta["low_power"] = ProcessInfo.processInfo.isLowPowerModeEnabled ? "true" : "false"
        record(.info, .performance, "perf_snapshot", meta)
    }

    // MARK: - Export

    /// Format the retained log as a single plain-text document.
    func exportText() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var lines: [String] = []
        lines.append("Chau7 Remote — Diagnostics Export")
        lines.append("Generated: \(formatter.string(from: Date()))")
        lines.append("App version: \(RemoteClient.appVersion)")
        lines.append("Device: \(UIDevice.current.model) — iOS \(UIDevice.current.systemVersion)")
        lines.append("Entries retained: \(entries.count) (total recorded: \(totalRecorded))")
        lines.append("Keystroke logging: \(isKeystrokeLoggingEnabled ? "on" : "off"), verbose: \(isVerboseLoggingEnabled ? "on" : "off")")
        lines.append(String(repeating: "─", count: 48))

        for entry in entries {
            let time = formatter.string(from: entry.timestamp)
            var line = "\(time) [\(entry.levelValue)] \(entry.category): \(entry.message)"
            if !entry.metadata.isEmpty {
                let meta = entry.metadata
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: " ")
                line += "  {\(meta)}"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n").appending("\n")
    }

    /// Write the export to a temporary file and return its URL (for ShareLink).
    func exportFile() -> URL? {
        let text = exportText()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "chau7-diagnostics-\(formatter.string(from: Date())).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try text.data(using: .utf8)?.write(to: url, options: .atomic)
            return url
        } catch {
            osLog.error("Diagnostics export failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Drop all retained entries (and the on-disk copy).
    func clear() {
        entries.removeAll()
        persistedEntryCount = 0
        needsFullRewrite = false
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        record(.info, .lifecycle, "Diagnostics log cleared")
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, let fileURL = self.fileURL else { return }
            // Debounced autosave: encode on the main actor (Entry's Codable
            // conformance is main-isolated), then hand the finished bytes to the
            // serial queue so the 2-second tick never hitches the UI.
            // Incremental: only new entries are encoded and appended; a full
            // rewrite happens only after the ring trims (the old code
            // re-encoded all ≤8000 entries every tick).
            self.persist(synchronously: false)
        }
    }

    /// Encode the un-persisted tail (or the whole buffer after a trim) and
    /// hand it to the serial write queue. Cursor updates happen here on the
    /// main actor; the queue is FIFO so writes land in order.
    private func persist(synchronously: Bool) {
        guard let fileURL else { return }
        let work: @Sendable () -> Void
        if needsFullRewrite || persistedEntryCount > entries.count {
            let data = Self.encodeEntries(entries)
            work = { Self.writeData(data, to: fileURL) }
            needsFullRewrite = false
        } else {
            let newEntries = Array(entries.dropFirst(persistedEntryCount))
            guard !newEntries.isEmpty else { return }
            let data = Self.encodeEntries(newEntries)
            work = { Self.appendData(data, to: fileURL) }
        }
        persistedEntryCount = entries.count
        if synchronously {
            saveQueue.sync(execute: work)
        } else {
            saveQueue.async(execute: work)
        }
    }

    /// Flush immediately and *synchronously* (e.g. on backgrounding) so nothing
    /// is lost if iOS suspends or kills the app right after this returns.
    /// Running on the serial queue with `sync` both drains any in-flight
    /// debounced write and guarantees this newer snapshot lands last.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        persist(synchronously: true)
    }

    /// Serialize entries to newline-delimited JSON. Runs on the main actor
    /// because `Entry`'s `Codable` conformance is main-actor-isolated; both
    /// callers already hold the actor.
    private static func encodeEntries(_ entries: [Entry]) -> Data {
        let encoder = JSONEncoder()
        var data = Data()
        for entry in entries {
            guard let line = try? encoder.encode(entry) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        return data
    }

    /// Write pre-encoded bytes atomically. Pure and non-isolated so both the
    /// debounced (off-main) and synchronous flush paths can share it off the
    /// main actor; `Data` is `Sendable`, so nothing actor-isolated crosses.
    private nonisolated static func writeData(_ data: Data, to fileURL: URL) {
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Append pre-encoded JSONL bytes; falls back to a plain write when the
    /// file doesn't exist yet.
    private nonisolated static func appendData(_ data: Data, to fileURL: URL) {
        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            try? data.write(to: fileURL, options: .atomic)
            return
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Fall back to a full rewrite attempt on the next save cycle.
        }
    }

    private func load() {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        let decoder = JSONDecoder()
        var loaded: [Entry] = []
        var decodedLineCount = 0
        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let entry = try? decoder.decode(Entry.self, from: lineData) else {
                continue
            }
            decodedLineCount += 1
            loaded.append(entry)
        }
        if loaded.count > Self.maxEntries {
            loaded.removeFirst(loaded.count - Self.maxEntries)
        }
        entries = loaded
        persistedEntryCount = loaded.count
        // When the file held more lines than the buffer keeps (trimmed on
        // load), the file and cursor disagree — rewrite once on the next save.
        needsFullRewrite = decodedLineCount != loaded.count
        nextID = (loaded.last?.id ?? 0) + 1
        totalRecorded = UInt64(loaded.count)
    }

    // MARK: - Helpers

    private func mirrorToOSLog(_ entry: Entry) {
        // Keystroke entries carry literal typed text (potentially secrets).
        // They live only in the bounded, clearable, export-only in-app buffer
        // and must never be copied into the system unified log.
        if entry.category == Category.keystroke.rawValue { return }
        let text = "\(entry.category): \(entry.message)"
        switch entry.levelValue {
        case .trace, .debug:
            osLog.debug("\(text, privacy: .public)")
        case .info:
            osLog.info("\(text, privacy: .public)")
        case .warn:
            osLog.warning("\(text, privacy: .public)")
        case .error:
            osLog.error("\(text, privacy: .public)")
        }
    }

    private static func describeKeystroke(_ value: String) -> String {
        switch value {
        case "\u{1B}": return "<esc>"
        case "\t": return "<tab>"
        case "\n", "\r": return "<return>"
        case " ": return "<space>"
        case "\u{7F}", "\u{08}": return "<delete>"
        default:
            return value
        }
    }

    private static func thermalStateDescription(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// Resident memory footprint of this process, in bytes, or nil if the
    /// Mach query fails.
    private static func memoryFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), reboundPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.phys_footprint
    }
}
