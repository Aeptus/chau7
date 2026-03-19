import Foundation
import Chau7Core

/// Generic file tailer that monitors a file for new content.
/// Replaces EventTailer, HistoryTailer, and TextTailer with a single implementation.
final class FileTailer<T> {
    private let fileURL: URL
    private let parser: (String) throws -> T
    private let onItem: (T) -> Void
    private let pollInterval: DispatchTimeInterval
    private let createIfMissing: Bool

    private var timer: DispatchSourceTimer?
    private var offset: UInt64 = 0
    private var buffer = ""
    private let queue: DispatchQueue
    private var readHandle: FileHandle?
    private var parseErrorCount = 0
    private let maxParseErrorLogs = 10

    // MARK: - Memory Protection

    /// Maximum buffer size to prevent OOM with malformed files.
    /// Default 4MB; PTY log tailers should use 8MB for AI streaming headroom.
    private let maxBufferSize: Int

    init(
        fileURL: URL,
        pollInterval: DispatchTimeInterval = .milliseconds(500),
        createIfMissing: Bool = false,
        maxBufferSize: Int = 4 * 1024 * 1024,
        queueLabel: String = "com.chau7.tailer",
        parser: @escaping (String) throws -> T,
        onItem: @escaping (T) -> Void
    ) {
        self.fileURL = fileURL
        self.pollInterval = pollInterval
        self.createIfMissing = createIfMissing
        self.maxBufferSize = maxBufferSize
        self.queue = DispatchQueue(label: queueLabel)
        self.parser = parser
        self.onItem = onItem
    }

    /// Starts monitoring the file for new content.
    /// - Parameter prefillLines: Number of existing lines to read initially (0 = start fresh)
    func start(prefillLines: Int = 0) {
        if createIfMissing, !FileManager.default.fileExists(atPath: fileURL.path) {
            Log.warn("File not found. Creating empty file at \(fileURL.path)")
            FileManager.default.createFile(atPath: fileURL.path, contents: Data(), attributes: nil)
        }

        if prefillLines > 0 {
            prefillLastLines(count: prefillLines)
        }

        offset = currentFileSize() ?? 0
        Log.trace("FileTailer start. path=\(fileURL.path) offset=\(offset)")

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: pollInterval)
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        self.timer = timer
    }

    /// Stops monitoring and cleans up resources.
    func stop() {
        timer?.cancel()
        timer = nil
        buffer = ""
        try? readHandle?.close()
        readHandle = nil
        Log.trace("FileTailer stop. path=\(fileURL.path)")
    }

    private func openReadHandle() {
        try? readHandle?.close()
        readHandle = try? FileHandle(forReadingFrom: fileURL)
    }

    private func tick() {
        if let size = currentFileSize(), size < offset {
            offset = 0
            buffer = ""
            openReadHandle()
            Log.trace("FileTailer reset after truncation. path=\(fileURL.path)")
        }

        if readHandle == nil {
            openReadHandle()
        }
        guard let handle = readHandle else {
            Log.trace("FileTailer read failed. path=\(fileURL.path)")
            return
        }

        do {
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            if data.isEmpty { return }

            offset += UInt64(data.count)
            Log.trace("FileTailer read \(data.count) bytes. path=\(fileURL.path)")
            let chunk = String(decoding: data, as: UTF8.self)

            // Process-then-discard: prepend any trailing fragment from the previous
            // tick, split into lines, parse all complete lines immediately, and only
            // keep the incomplete trailing fragment. The buffer never grows beyond
            // one partial line.
            let working = buffer.isEmpty ? chunk : buffer + chunk
            buffer = ""

            let normalized = working.replacingOccurrences(of: "\r", with: "\n")
            let parts = normalized.components(separatedBy: "\n")
            guard !parts.isEmpty else { return }

            for line in parts.dropLast() {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                do {
                    let item = try parser(trimmed)
                    onItem(item)
                } catch {
                    parseErrorCount += 1
                    if parseErrorCount <= maxParseErrorLogs {
                        Log.warn("FileTailer parse failed (\(parseErrorCount)): \(error). line=\(trimmed.prefix(120))")
                    }
                }
            }

            buffer = parts.last ?? ""

            // Safety net: if a single line somehow exceeds maxBufferSize (e.g. binary
            // data written to the tailed file), discard it to prevent OOM.
            if buffer.count > maxBufferSize {
                Log.trace("FileTailer trailing fragment exceeded \(maxBufferSize) bytes, discarding. path=\(fileURL.path)")
                buffer = ""
            }
        } catch {
            Log.trace("FileTailer error: \(error.localizedDescription)")
            // Handle became invalid (file deleted/replaced), reopen on next tick
            try? readHandle?.close()
            readHandle = nil
        }
    }

    private func currentFileSize() -> UInt64? {
        try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? UInt64
    }

    private func prefillLastLines(count: Int) {
        guard count > 0 else { return }
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return }
        defer { try? handle.close() }

        guard let size = currentFileSize(), size > 0 else { return }
        let maxBytes: UInt64 = 2 * 1024 * 1024
        let readSize = min(size, maxBytes)
        let startOffset = size - readSize

        do {
            try handle.seek(toOffset: startOffset)
            let data = try handle.readToEnd() ?? Data()
            let text = String(decoding: data, as: UTF8.self)
            let normalized = text.replacingOccurrences(of: "\r", with: "\n")
            var parts = normalized.components(separatedBy: "\n")
            if let last = parts.last, last.isEmpty {
                parts.removeLast()
            }
            let tail = parts.suffix(count)
            if !tail.isEmpty {
                Log.trace("FileTailer prefill \(tail.count) lines. path=\(fileURL.path)")
            }
            for line in tail {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                do {
                    let item = try parser(trimmed)
                    onItem(item)
                } catch {
                    // Silently skip unparseable prefill lines
                }
            }
        } catch {
            Log.trace("FileTailer prefill error: \(error.localizedDescription)")
        }
    }
}

// MARK: - Convenience Factory Methods

extension FileTailer where T == AIEvent {
    /// Creates a tailer for AI event log files.
    static func eventTailer(
        fileURL: URL,
        onEvent: @escaping (AIEvent) -> Void
    ) -> FileTailer<AIEvent> {
        FileTailer(
            fileURL: fileURL,
            pollInterval: .milliseconds(500),
            queueLabel: "com.chau7.eventTailer",
            parser: { try AIEventParser.parse(line: $0) },
            onItem: onEvent
        )
    }
}

extension FileTailer where T == HistoryEntry {
    /// Creates a tailer for history JSONL files.
    static func historyTailer(
        fileURL: URL,
        onEntry: @escaping (HistoryEntry) -> Void
    ) -> FileTailer<HistoryEntry> {
        FileTailer(
            fileURL: fileURL,
            pollInterval: .milliseconds(500),
            createIfMissing: true,
            queueLabel: "com.chau7.historyTailer",
            parser: { try HistoryEntryParser.parse(line: $0) },
            onItem: onEntry
        )
    }
}

extension FileTailer where T == String {
    /// Creates a tailer for plain text log files.
    static func textTailer(
        fileURL: URL,
        onLine: @escaping (String) -> Void
    ) -> FileTailer<String> {
        FileTailer(
            fileURL: fileURL,
            pollInterval: .milliseconds(250),
            createIfMissing: true,
            maxBufferSize: 8 * 1024 * 1024,
            queueLabel: "com.chau7.textTailer",
            parser: { $0 }, // Identity parser - just return the line
            onItem: onLine
        )
    }
}
