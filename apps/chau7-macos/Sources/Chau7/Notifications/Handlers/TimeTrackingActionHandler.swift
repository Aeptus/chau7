import Foundation
import Chau7Core

/// Shared handler for the three time-tracking actions (startTimer,
/// stopTimer, logTime). Registered once and routed to from all three
/// type keys so the trio shares one `activeTimers` map.
@MainActor
final class TimeTrackingActionHandler: NotificationActionHandler {
    let supportedActionTypes: [NotificationActionType] = [.startTimer, .stopTimer, .logTime]

    private var activeTimers: [String: Date] = [:]

    func execute(payload: ActionPayload, environment _: ActionEnvironment) -> NotificationActionExecutor.ExecutionReport {
        switch payload.config.actionType {
        case .startTimer: return start(payload: payload)
        case .stopTimer: return stop(payload: payload)
        case .logTime: return log(payload: payload)
        default:
            assertionFailure("TimeTrackingActionHandler routed an unexpected type: \(payload.config.actionType)")
            return NotificationActionExecutor.ExecutionReport()
        }
    }

    // MARK: - startTimer

    private func start(payload: ActionPayload) -> NotificationActionExecutor.ExecutionReport {
        let timerName = payload.interpolate(payload.configValue("timerName") ?? payload.event.tool)
        let project = payload.configValue("project") ?? ""
        activeTimers[timerName] = Date()
        Log.info("Action startTimer: Started '\(timerName)' for project '\(project)'")
        var report = NotificationActionExecutor.ExecutionReport()
        report.recordSuccess(.startTimer)
        return report
    }

    // MARK: - stopTimer

    private func stop(payload: ActionPayload) -> NotificationActionExecutor.ExecutionReport {
        let timerName = payload.configValue("timerName")
        var stoppedTimer: (name: String, start: Date)?

        if let name = timerName, !name.isEmpty {
            if let start = activeTimers.removeValue(forKey: name) {
                stoppedTimer = (name, start)
            }
        } else if let (name, start) = activeTimers.first {
            activeTimers.removeValue(forKey: name)
            stoppedTimer = (name, start)
        }

        if let timer = stoppedTimer {
            let duration = Date().timeIntervalSince(timer.start)
            let minutes = Int(duration / 60)
            let seconds = Int(duration) % 60
            Log.info("Action stopTimer: Stopped '\(timer.name)' after \(minutes)m \(seconds)s")
        } else {
            Log.warn("Action stopTimer: No active timer found")
        }
        var report = NotificationActionExecutor.ExecutionReport()
        if stoppedTimer != nil {
            report.recordSuccess(.stopTimer)
        } else {
            report.recordFailure("stopTimer found no active timer")
        }
        return report
    }

    // MARK: - logTime

    private func log(payload: ActionPayload) -> NotificationActionExecutor.ExecutionReport {
        let service = payload.configValue("service") ?? "file"
        let description = payload.interpolate(payload.configValue("description") ?? "${type}: ${message}")

        switch service {
        case "file":
            let filePath = payload.configValue("filePath") ?? "~/time-log.csv"
            let expandedPath = RuntimeIsolation.expandTilde(in: filePath)
            let entry = "\(payload.event.ts),\"\(description.replacingOccurrences(of: "\"", with: "\"\""))\""

            do {
                let fileURL = URL(fileURLWithPath: expandedPath)
                let directory = fileURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

                // O_CREAT|O_EXCL writes the header only when the file is fresh.
                let fd = open(expandedPath, O_WRONLY | O_CREAT | O_EXCL, 0o644)
                if fd >= 0 {
                    let header = "timestamp,description\n"
                    header.withCString { _ = write(fd, $0, header.utf8.count) }
                    close(fd)
                }

                if let entryData = (entry + "\n").data(using: .utf8) {
                    try appendToFile(atPath: expandedPath, data: entryData)
                }
                Log.info("Action logTime: Logged to \(filePath)")
            } catch {
                Log.error("Action logTime: Failed to write file: \(error.localizedDescription)")
                var report = NotificationActionExecutor.ExecutionReport()
                report.recordFailure("logTime failed: \(error.localizedDescription)")
                return report
            }

        default:
            Log.warn("Action logTime: Unknown service: \(service)")
            var report = NotificationActionExecutor.ExecutionReport()
            report.recordFailure("logTime unknown service: \(service)")
            return report
        }
        var report = NotificationActionExecutor.ExecutionReport()
        report.recordSuccess(.logTime)
        return report
    }

    /// Exposed for `NotificationActionExecutor.resetForTesting()`.
    func reset() {
        activeTimers.removeAll()
    }
}
