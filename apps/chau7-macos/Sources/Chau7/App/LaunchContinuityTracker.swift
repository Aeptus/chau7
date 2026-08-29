import AppKit
import Foundation
import Chau7Core

@MainActor
final class LaunchContinuityTracker {
    static let shared = LaunchContinuityTracker()

    private enum Key {
        static let running = "launchContinuity.running"
        static let build = "launchContinuity.build"
        static let startedAt = "launchContinuity.startedAt"
    }

    private var terminationObserver: NSObjectProtocol?

    private init() {}

    func start() {
        guard terminationObserver == nil else { return }

        let defaults = UserDefaults.standard
        let marker = defaults.object(forKey: Key.running) as? Bool
        let previousOutcome = LaunchContinuityPolicy.previousOutcome(isRunningMarker: marker)
        let previousBuild = defaults.string(forKey: Key.build) ?? "unknown"
        let previousStartedAt = defaults.object(forKey: Key.startedAt) as? Date
        let currentBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"

        defaults.set(true, forKey: Key.running)
        defaults.set(currentBuild, forKey: Key.build)
        defaults.set(Date(), forKey: Key.startedAt)
        defaults.synchronize()

        let previousStarted = previousStartedAt.map { DateFormatters.iso8601.string(from: $0) } ?? "unknown"
        let message = "Launch continuity previous=\(previousOutcome.rawValue) " +
            "previous_build=\(previousBuild) previous_started=\(previousStarted) " +
            "current_build=\(currentBuild) pid=\(ProcessInfo.processInfo.processIdentifier)"
        if previousOutcome == .abrupt {
            Log.warn(message)
        } else {
            Log.info(message)
        }

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: NSApp,
            queue: .main
        ) { _ in
            Task { @MainActor in
                LaunchContinuityTracker.shared.markCleanTermination()
            }
        }
    }

    private func markCleanTermination() {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: Key.running)
        defaults.synchronize()
        Log.info("Launch continuity marked clean termination")
    }
}
