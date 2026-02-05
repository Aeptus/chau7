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
    @Published var isConnected: Bool = false
    @Published var sessionName: String?
    @Published var windows: [TmuxWindow] = []
    @Published var lastError: String?

    private let parser = TmuxControlParser()
    private var outputHandler: ((String) -> Void)?

    func connect(sessionName: String? = nil) {
        let cmd: String
        if let name = sessionName {
            let sanitized = Self.sanitizeTmuxArg(name)
            cmd = "tmux -CC attach -t \(sanitized)"
        } else {
            cmd = "tmux -CC new"
        }
        Log.info("TmuxControlMode: connecting with '\(cmd)'")
        // Send command to terminal...
        isConnected = true
    }

    func disconnect() {
        send("detach")
        isConnected = false
        windows.removeAll()
        Log.info("TmuxControlMode: disconnected")
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
            outputHandler?(data)
            Log.trace("TmuxControlMode: output on pane \(paneID)")

        case .layoutChange(let windowID, let layout):
            updateLayout(windowID: windowID, layout: layout)

        case .exit(let reason):
            isConnected = false
            Log.info("TmuxControlMode: exited, reason=\(reason ?? "none")")

        case .error(_, _, let msg):
            lastError = msg
            Log.error("TmuxControlMode: error: \(msg)")

        default:
            break
        }
    }

    /// Send a tmux command
    func send(_ command: String) {
        Log.trace("TmuxControlMode: sending '\(command)'")
        // Write command + newline to the tmux control mode session
    }

    // tmux commands
    func newWindow(name: String? = nil) {
        send("new-window" + (name.map { " -n \(Self.sanitizeTmuxArg($0))" } ?? ""))
    }
    func selectWindow(id: String) { send("select-window -t \(Self.sanitizeTmuxArg(id))") }
    func renameWindow(id: String, name: String) {
        send("rename-window -t \(Self.sanitizeTmuxArg(id)) \(Self.sanitizeTmuxArg(name))")
    }
    func splitPane(direction: SplitDirection) { send("split-window \(direction == .horizontal ? "-h" : "-v")") }
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
    var isActive: Bool = false
}

struct TmuxPane: Identifiable, Equatable {
    let id: String
    var isActive: Bool = false
    var width: Int = 80
    var height: Int = 24
}
