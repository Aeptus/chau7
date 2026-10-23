import Foundation

/// Incremental reader for append-only JSONL files (Codex rollouts). Keeps a
/// (size, mtime, offset, partial-line carry) cursor per file so a periodic
/// scan costs one stat when nothing changed and reads only the appended bytes
/// when something did — never the whole file.
public enum JSONLTailReader {
    public struct State: Equatable {
        public let path: String
        public let fileSize: UInt64
        public let modificationDate: Date
        public let byteOffset: UInt64
        /// Bytes after the last newline (an in-progress line); prepended to
        /// the next read so lines split across reads stay whole.
        public let carry: Data

        public init(
            path: String,
            fileSize: UInt64,
            modificationDate: Date,
            byteOffset: UInt64,
            carry: Data
        ) {
            self.path = path
            self.fileSize = fileSize
            self.modificationDate = modificationDate
            self.byteOffset = byteOffset
            self.carry = carry
        }
    }

    public struct Chunk {
        /// Complete (newline-terminated) lines available since the last read,
        /// with any prior partial-line carry prepended. May be empty when only
        /// a partial line arrived.
        public let completeLinesText: String
        public let newState: State
    }

    /// Bounded first read: only the last 256 KB of an existing file. The
    /// records of interest live near the end of append-only rollouts.
    public static let firstReadTailBytes: UInt64 = 262_144
    /// A partial line larger than this is abandoned (corrupt/binary data)
    /// rather than carried forever.
    public static let maxCarryBytes = 1_048_576

    /// Returns the bytes appended since `state`, or nil when the file is
    /// unchanged (single stat, zero reads) or unreadable. Pass a nil state
    /// for the first read (bounded tail); a truncated or replaced file
    /// resets to a fresh bounded-tail read automatically.
    public static func readNewChunk(path: String, state: State?) -> Chunk? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let sizeNumber = attributes[.size] as? NSNumber else {
            return nil
        }
        let size = sizeNumber.uint64Value
        let modificationDate = (attributes[.modificationDate] as? Date) ?? Date()

        var effectiveState = state
        if let current = effectiveState {
            if current.path != path || size < current.byteOffset {
                // Different file, or truncated/recreated in place: restart.
                effectiveState = nil
            } else if size == current.fileSize, modificationDate == current.modificationDate {
                return nil
            }
        }

        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        let startOffset: UInt64
        var carry: Data
        var dropThroughFirstNewline = false
        if let current = effectiveState {
            startOffset = current.byteOffset
            carry = current.carry
        } else {
            carry = Data()
            if size > firstReadTailBytes {
                startOffset = size - firstReadTailBytes
                dropThroughFirstNewline = true
            } else {
                startOffset = 0
            }
        }

        guard (try? handle.seek(toOffset: startOffset)) != nil else { return nil }
        let wantedCount = Int(min(size - startOffset, UInt64(Int.max)))
        let readData = (try? handle.read(upToCount: wantedCount)) ?? Data()
        let consumedBytes = UInt64(readData.count)

        var newData = readData
        if dropThroughFirstNewline {
            if let newlineIndex = newData.firstIndex(of: 0x0A) {
                newData = Data(newData[newData.index(after: newlineIndex)...])
            } else {
                newData = Data()
            }
        }

        var combined = carry
        combined.append(newData)

        let completeLinesText: String
        var newCarry: Data
        if let lastNewline = combined.lastIndex(of: 0x0A) {
            let completeEnd = combined.index(after: lastNewline)
            completeLinesText = String(decoding: combined[..<completeEnd], as: UTF8.self)
            newCarry = Data(combined[completeEnd...])
        } else {
            completeLinesText = ""
            newCarry = combined
        }
        if newCarry.count > maxCarryBytes {
            newCarry = Data()
        }

        return Chunk(
            completeLinesText: completeLinesText,
            newState: State(
                path: path,
                fileSize: size,
                modificationDate: modificationDate,
                byteOffset: startOffset + consumedBytes,
                carry: newCarry
            )
        )
    }
}
