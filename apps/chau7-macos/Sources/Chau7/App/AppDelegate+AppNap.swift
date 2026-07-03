import AppKit
import Chau7Core

/// App Nap prevention / latency-critical activity management, split out of
/// AppDelegate.swift verbatim. The IOKit-style `NSObjectProtocol` activity token
/// and its bookkeeping (`isAppActive`, `latencyCriticalScopes`, `appNapObservers`,
/// `activityToken`, `telemetryRepairWorkItem`) remain stored on AppDelegate — Swift
/// forbids stored properties in extensions — so only the methods move here.
extension AppDelegate {

    // MARK: - App Nap Management

    func startAppNapManagement() {
        enableLowLatency()

        let activateObs = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isAppActive = true
                self?.telemetryRepairWorkItem?.cancel()
                self?.telemetryRepairWorkItem = nil
                self?.enableLowLatency()
                // Returning to the app is the moment a repo may have been moved
                // in Finder; heal any group tags now orphaned by the move.
                self?.reconcileStaleRepoGroupsAcrossWindows()
            }
        }
        let resignObs = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isAppActive = false
                self?.scheduleRecentTelemetryRepairSweep()
                self?.refreshLowLatencyActivity()
            }
        }
        appNapObservers = [activateObs, resignObs]
        Log.info("App Nap management started (conditional latency-critical activity)")
    }

    private func enableLowLatency() {
        refreshLowLatencyActivity()
    }

    /// Re-tags tabs whose repo group points at a directory that no longer
    /// exists (e.g. after the repo was moved or renamed on disk) across every
    /// open window. Cheap and idempotent — a no-op when nothing has moved.
    private func reconcileStaleRepoGroupsAcrossWindows() {
        for host in overlayHosts {
            host.model.reconcileStaleRepoGroups()
        }
    }

    func refreshLowLatencyActivity() {
        let hasLatencyCriticalScopes = !latencyCriticalScopes.isEmpty
        let hasVisibleLiveWindows = hasVisibleLiveWindowsForLowLatency
        let shouldHoldLowLatency = LowLatencyActivityPolicy.shouldHoldActivity(
            LowLatencyActivityPolicyInput(
                isAppActive: isAppActive,
                hasLatencyCriticalScopes: hasLatencyCriticalScopes,
                hasVisibleLiveWindows: hasVisibleLiveWindows
            )
        )
        if shouldHoldLowLatency {
            guard activityToken == nil else { return }
            activityToken = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                reason: "Terminal requires low-latency input processing"
            )
            let scopeSummary = latencyCriticalScopes.keys.sorted().joined(separator: ",")
            Log.info("App Nap: acquired latency-critical activity active=\(isAppActive) scopes=\(scopeSummary.isEmpty ? "(none)" : scopeSummary)")
            return
        }

        guard let activityToken else { return }
        ProcessInfo.processInfo.endActivity(activityToken)
        self.activityToken = nil
        Log.info(
            "App Nap: released latency-critical activity active=\(isAppActive) scopes=\(hasLatencyCriticalScopes) visibleLiveWindows=\(hasVisibleLiveWindows)"
        )
    }

    func beginLatencyCriticalScope(reason: String, timeout: TimeInterval) {
        latencyCriticalScopes[reason]?.cancel()
        let releaseWorkItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.endLatencyCriticalScope(reason: reason)
            }
        }
        latencyCriticalScopes[reason] = releaseWorkItem
        enableLowLatency()
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: releaseWorkItem)
        Log.info("App Nap: began latency-critical scope reason=\(reason) timeout=\(Int(timeout.rounded()))s")
    }

    func endLatencyCriticalScope(reason: String) {
        guard let item = latencyCriticalScopes.removeValue(forKey: reason) else { return }
        item.cancel()
        refreshLowLatencyActivity()
        Log.info("App Nap: ended latency-critical scope reason=\(reason)")
    }

    private var hasVisibleLiveWindowsForLowLatency: Bool {
        overlayHosts.contains { host in
            host.model.shouldHoldLowLatencyWhileInactive
        }
    }

    /// Revisit recent incomplete transcript-derived runs after launch.
    /// This catches delayed transcript flushes and app restarts without forcing a
    /// heavyweight telemetry rewrite sweep onto the active startup/input path.
    private func scheduleRecentTelemetryRepairSweep() {
        telemetryRepairWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard !isAppActive else { return }

            let report = TelemetryRepairService.shared.rebuildRecentIncompleteRuns(limit: 50)
            guard report.inspectedRuns > 0 else { return }
            Log.info(
                "Deferred telemetry repair sweep inspected=\(report.inspectedRuns) rebuilt=\(report.rebuiltRuns) invalidated=\(report.invalidatedRuns) skipped=\(report.skippedRuns)"
            )
        }
        telemetryRepairWorkItem = workItem
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120, execute: workItem)
    }
}
