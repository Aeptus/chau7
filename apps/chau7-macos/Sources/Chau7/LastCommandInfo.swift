import Foundation

// MARK: - F20: Last Command Tracker

/// Information about the last executed command for badge display
struct LastCommandInfo: Equatable {
    let command: String
    let startTime: Date
    var endTime: Date?
    var exitCode: Int32?

    var duration: TimeInterval? {
        guard let end = endTime else { return nil }
        return end.timeIntervalSince(startTime)
    }

    var durationString: String {
        guard let d = duration else { return "" }
        if d < 1 {
            return String(format: "%.0fms", d * 1000)
        } else if d < 60 {
            return String(format: "%.1fs", d)
        } else if d < 3600 {
            let mins = Int(d) / 60
            let secs = Int(d) % 60
            return "\(mins)m \(secs)s"
        } else {
            let hours = Int(d) / 3600
            let mins = (Int(d) % 3600) / 60
            return "\(hours)h \(mins)m"
        }
    }

    var statusIcon: String {
        guard let code = exitCode else { return "⏳" }
        return code == 0 ? "✓" : "✗"
    }

    var badgeText: String {
        guard let _ = exitCode else { return "..." }
        return "\(statusIcon) \(durationString)"
    }
}
