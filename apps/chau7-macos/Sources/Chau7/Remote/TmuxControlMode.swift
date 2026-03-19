import Foundation
import Chau7Core

/// Manages a tmux control mode connection (tmux -CC).
/// Maps tmux windows/panes to Chau7 tabs and panes.
///
/// When connected:
/// - tmux windows appear as Chau7 tabs
/// - tmux panes map to Chau7 split panes
/// - tmux session state is synchronized both ways
@MainActor
final class TmuxControlMode: ObservableObject {
    @Published var isConnected = false
    @Published var sessionName: String?
    @Published var windows: [TmuxWindow] = []
    @Published var lastError: String?

    private let parser = TmuxControlParser()
    /// Callback for pane output data (routed to the corresponding terminal view)
    var outputHandler: ((String, String) -> Void)? // (paneID, data)

    /// The tmux process and its stdin pipe for sending commands
    private var process: Process?
    private var stdinPipe: Pipe?
    private var readerTask: Task<Void, Never>?

    func connect(sessionName: String? = nil) {
        guard !isConnected else { return }

        let args: [String]
        if let name = sessionName {
            let sanitized = Self.sanitizeTmuxArg(name)
            args = ["-CC", "attach", "-t", sanitized]
        } else {
            args = ["-CC", "new"]
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["tmux"] + args

        let stdin = Pipe()
        let stdout = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            lastError = error.localizedDescription
            Log.error("TmuxControlMode: failed to launch tmux: \(error)")
            return
        }

        self.process = proc
        self.stdinPipe = stdin
        self.isConnected = true
        Log.info("TmuxControlMode: connected with tmux \(args.joined(separator: " "))")

        // Read stdout line-by-line on a background task
        readerTask = Task.detached { [weak self] in
            let handle = stdout.fileHandleForReading
            var buffer = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break } // EOF
                buffer.append(chunk)

                // Split on newlines and process complete lines
                while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let lineData = buffer[buffer.startIndex ..< newlineIndex]
                    buffer = Data(buffer[buffer.index(after: newlineIndex)...])
                    guard let line = String(data: lineData, encoding: .utf8) else { continue }
                    await MainActor.run { [weak self] in
                        self?.processLine(line)
                    }
                }
            }

            // Process exited
            await MainActor.run { [weak self] in
                self?.isConnected = false
                self?.process = nil
                Log.info("TmuxControlMode: process exited")
            }
        }

        // List existing windows on connect
        send("list-windows -F '#{window_id} #{window_name}'")
    }

    func disconnect() {
        send("detach")
        cleanup()
        Log.info("TmuxControlMode: disconnected")
    }

    private func cleanup() {
        readerTask?.cancel()
        readerTask = nil
        process?.terminate()
        process = nil
        stdinPipe = nil
        isConnected = false
        windows.removeAll()
    }

    /// Process a line of output from the tmux control mode session
    func processLine(_ line: String) {
        let notification = parser.parseLine(line)

        switch notification {
        case .sessionChanged(let id, let name):
            sessionName = name
            Log.info("TmuxControlMode: session changed to '\(name)' (\(id))")

        case .windowAdd(let windowID):
            let window = TmuxWindow(id: windowID, name: "Window")
            windows.append(window)
            Log.info("TmuxControlMode: window added \(windowID)")

        case .windowClose(let windowID):
            windows.removeAll { $0.id == windowID }
            Log.info("TmuxControlMode: window closed \(windowID)")

        case .output(let paneID, let data):
            outputHandler?(paneID, data)
            Log.trace("TmuxControlMode: output on pane \(paneID)")

        case .layoutChange(let windowID, let layout):
            updateLayout(windowID: windowID, layout: layout)

        case .exit(let reason):
            cleanup()
            Log.info("TmuxControlMode: exited, reason=\(reason ?? "none")")

        case .error(_, _, let msg):
            lastError = msg
            Log.error("TmuxControlMode: error: \(msg)")

        default:
            break
        }
    }

    /// Send a tmux command via the control mode stdin pipe
    func send(_ command: String) {
        guard let pipe = stdinPipe else {
            Log.warn("TmuxControlMode: send() called but not connected")
            return
        }
        let data = Data((command + "\n").utf8)
        pipe.fileHandleForWriting.write(data)
        Log.trace("TmuxControlMode: sent '\(command)'")
    }

    /// tmux commands
    func newWindow(name: String? = nil) {
        send("new-window" + (name.map { " -n \(Self.sanitizeTmuxArg($0))" } ?? ""))
    }

    func selectWindow(id: String) {
        send("select-window -t \(Self.sanitizeTmuxArg(id))")
    }

    func renameWindow(id: String, name: String) {
        send("rename-window -t \(Self.sanitizeTmuxArg(id)) \(Self.sanitizeTmuxArg(name))")
    }

    func splitPane(direction: SplitDirection) {
        send("split-window \(direction == .horizontal ? "-h" : "-v")")
    }

    func resizePane(direction: ResizeDirection, amount: Int) {
        let clamped = min(max(amount, 1), 1000)
        send("resize-pane -\(direction.flag) \(clamped)")
    }

    /// Sanitize a string for use as a tmux command argument.
    /// Strips shell metacharacters to prevent command injection.
    private static func sanitizeTmuxArg(_ arg: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:/@"))
        return String(arg.unicodeScalars.filter { allowed.contains($0) })
    }

    enum ResizeDirection {
        case up, down, left, right

        var flag: String {
            switch self {
            case .up: return "U"
            case .down: return "D"
            case .left: return "L"
            case .right: return "R"
            }
        }
    }

    private func updateLayout(windowID: String, layout: String) {
        Log.trace("TmuxControlMode: layout change for \(windowID): \(layout)")
    }

    enum SplitDirection { case horizontal, vertical }
}

struct TmuxWindow: Identifiable, Equatable {
    let id: String
    var name: String
    var panes: [TmuxPane] = []
    var isActive = false
}

struct TmuxPane: Identifiable, Equatable {
    let id: String
    var isActive = false
    var width = 80
    var height = 24
}
