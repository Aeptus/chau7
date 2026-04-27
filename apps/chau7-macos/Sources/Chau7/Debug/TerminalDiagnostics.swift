import AppKit
import Chau7Core
import Foundation

/// Writes a forensic snapshot of the active terminal's grid + recent PTY
/// bytes to `~/Library/Logs/Chau7/grid-dump-<timestamp>.log`.
///
/// Use this when an erratic rendering bug appears on screen but is hard to
/// reproduce on demand: the user triggers the dump from the Command Palette
/// the moment they see the issue, and we get a freeze-frame of the grid
/// state plus the byte stream that produced it. The pair lets us replay
/// the bytes locally and diff Chau7's render against any other terminal.
///
/// Output sections (in order):
///   1. **Tab metadata** — title, owner UUID, cwd, AI provider/session
///   2. **Terminal dims** — cols × rows, cell size, bounds, cursor position,
///      scrollback history size, display offset
///   3. **Grid (styled ANSI text)** — what `getStyledBufferAsData` returns:
///      every visible + scrollback row, with SGR colour state preserved
///   4. **Recent PTY tail** — last ~200 KB of bytes from the relevant
///      `<provider>-pty.log` (Claude / Codex), so we can replay them into
///      another terminal and compare
///
/// All paths are local; nothing leaves the user's machine. The file is
/// written with the user's normal umask — review before sharing.
enum TerminalDiagnostics {

    private static let recentPtyByteCap = 200_000

    /// Snapshot the active terminal and write a diagnostic file. Returns
    /// the file URL on success, nil on failure (no active terminal, or I/O
    /// error). Call from the main thread.
    @discardableResult
    @MainActor
    static func dump(
        view: RustTerminalView,
        tabTitle: String?,
        ownerTabID: UUID?,
        currentDirectory: String,
        aiProvider: String?,
        aiSessionId: String?
    ) -> URL? {
        // Filename-safe ISO timestamp — colons are allowed by HFS+ but
        // Finder displays them as `/`. Replace with hyphens.
        let raw = ISO8601DateFormatter.dumpFilename.string(from: Date())
        let timestamp = raw.replacingOccurrences(of: ":", with: "-")
        let logsDir = RuntimeIsolation.logsDirectory()
        let outputURL = logsDir.appendingPathComponent("grid-dump-\(timestamp).log")

        var output = ""
        output.reserveCapacity(256_000)

        // 1. Tab metadata
        output += "=== Chau7 Terminal Diagnostics ===\n"
        output += "wallTime: \(Date())\n"
        output += "[tab]\n"
        output += "  title: \(tabTitle ?? "<nil>")\n"
        output += "  ownerTabID: \(ownerTabID?.uuidString ?? "<nil>")\n"
        output += "  cwd: \(currentDirectory)\n"
        output += "  aiProvider: \(aiProvider ?? "<nil>")\n"
        output += "  aiSessionId: \(aiSessionId ?? "<nil>")\n"
        output += "\n"

        // 2. Terminal dims + cursor
        let bounds = view.bounds
        let cellSize = view.renderCellSize
        let cursor = view.rustTerminal?.cursorPosition
        let displayOffset = view.rustTerminal?.displayOffset ?? 0
        output += "[terminal]\n"
        output += "  cols × rows: \(view.renderCols) × \(view.renderRows)\n"
        output += "  cellWidth × cellHeight: \(cellSize.width) × \(cellSize.height)\n"
        output += "  bounds: (\(bounds.origin.x),\(bounds.origin.y),\(bounds.size.width),\(bounds.size.height))\n"
        if let cursor {
            output += "  cursor row × col: \(cursor.row) × \(cursor.col)\n"
        } else {
            output += "  cursor: <unavailable>\n"
        }
        output += "  scrollbackHistorySize: \(view.cachedScrollbackRows)\n"
        output += "  displayOffset: \(displayOffset) (>0 = scrolled up into history)\n"
        output += "  isInteractive: \(view.persistentTabID != nil)\n"
        output += "\n"

        // 3. Grid styled ANSI text
        output += "[grid — styled ANSI text follows; SGR sequences preserved]\n"
        if let data = view.getStyledBufferAsData(),
           let text = String(data: data, encoding: .utf8) {
            output += "  bytes: \(data.count)\n"
            output += "----- BEGIN GRID -----\n"
            output += text
            if !text.hasSuffix("\n") { output += "\n" }
            output += "----- END GRID -----\n"
        } else {
            output += "  <styled buffer unavailable>\n"
        }
        output += "\n"

        // 4. Recent PTY bytes for the relevant provider's log
        let ptyLogName: String? = {
            switch aiProvider?.lowercased() {
            case "claude": return "claude-pty.log"
            case "codex": return "codex-pty.log"
            case "chatgpt": return "chatgpt-pty.log"
            case "cline": return "cline-pty.log"
            case "gemini": return "gemini-pty.log"
            case "cursor": return "cursor-pty.log"
            default: return nil
            }
        }()
        output += "[pty-tail]\n"
        if let logName = ptyLogName {
            let ptyURL = logsDir.appendingPathComponent("Chau7").appendingPathComponent(logName)
            output += "  source: \(ptyURL.path)\n"
            if let tail = tailBytes(of: ptyURL, limit: recentPtyByteCap) {
                output += "  bytes: \(tail.count) (cap=\(recentPtyByteCap))\n"
                output += "----- BEGIN PTY TAIL -----\n"
                if let asText = String(data: tail, encoding: .utf8) {
                    output += asText
                } else {
                    // Bytes aren't clean UTF-8 (likely — escape sequences are
                    // single-byte). Hex-encode so the dump stays text-readable
                    // and we don't lose any byte fidelity for replay.
                    output += "  <not valid UTF-8; hex-encoded below>\n"
                    output += tail.map { String(format: "%02x", $0) }.joined(separator: " ")
                    output += "\n"
                }
                output += "\n----- END PTY TAIL -----\n"
            } else {
                output += "  <pty log unavailable or empty>\n"
            }
        } else {
            output += "  <no PTY log known for provider \(aiProvider ?? "<nil>")>\n"
        }

        do {
            try output.write(to: outputURL, atomically: true, encoding: .utf8)
            Log.info("TerminalDiagnostics: wrote \(output.count) bytes to \(outputURL.path)")
            return outputURL
        } catch {
            Log.error("TerminalDiagnostics: failed to write dump: \(error)")
            return nil
        }
    }

    /// Returns the last `limit` bytes of `url`, or nil on read error / empty
    /// file. Reads via FileHandle so we don't load multi-MB log files into
    /// memory in full.
    private static func tailBytes(of url: URL, limit: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let size: UInt64
        do {
            size = try handle.seekToEnd()
        } catch {
            return nil
        }
        let start = size > UInt64(limit) ? size - UInt64(limit) : 0
        do {
            try handle.seek(toOffset: start)
        } catch {
            return nil
        }
        return try? handle.readToEnd()
    }
}

private extension ISO8601DateFormatter {
    /// Filename-safe ISO timestamp (no colons; second precision).
    static let dumpFilename: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withDashSeparatorInDate,
                                   .withTime, .withColonSeparatorInTime]
        return formatter
    }()
}
