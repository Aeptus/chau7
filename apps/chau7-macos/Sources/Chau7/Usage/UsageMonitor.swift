import Foundation
import Observation
import Chau7Core

struct UsageProviderSummary: Identifiable {
    let provider: String
    let displayName: String
    let latestSnapshot: ProviderQuotaSnapshot?
    let recentRunConsumption: ProviderConsumptionStats?
    let windowMetrics: [ProviderQuotaWindowMetrics]
    let activeWarnings: [ProviderQuotaWarning]
    let statusMessage: String?

    var id: String {
        provider
    }
}

struct UsageLatencyMetricOverview: Identifiable {
    let metricKind: ProviderLatencyMetricKind
    let aggregate: ProviderLatencyAggregate

    var id: String {
        metricKind.rawValue
    }
}

struct UsageLatencyProviderOverview: Identifiable {
    let provider: String
    let displayName: String
    let sampledLatencyCount: Int
    let interactionCount: Int

    var id: String {
        provider
    }
}

struct UsageLatencyDashboard {
    let provider: String
    let displayName: String
    let metricKinds: [ProviderLatencyMetricKind]
    let aggregate: ProviderLatencyAggregate?
    let sampledCount: Int
    let totalInteractionCount: Int
    let dailyBuckets: [ProviderLatencyBucketPoint]
    let weekdayBuckets: [ProviderLatencyBucketPoint]
    let periodBuckets: [ProviderLatencyBucketPoint]
    let hourBuckets: [ProviderLatencyBucketPoint]
    let activityDailyBuckets: [ProviderActivityBucketPoint]
    let activityWeekdayBuckets: [ProviderActivityBucketPoint]
    let activityPeriodBuckets: [ProviderActivityBucketPoint]
    let activityHourBuckets: [ProviderActivityBucketPoint]
}

private struct CachedLatencySamples {
    let loadedAt: Date
    let samples: [ProviderLatencySample]
}

private struct CachedActivitySamples {
    let loadedAt: Date
    let samples: [ProviderActivitySample]
}

@Observable
final class UsageMonitor {
    static let shared = UsageMonitor()

    @ObservationIgnored private let fileManager = FileManager.default
    @ObservationIgnored private let refreshInterval: TimeInterval = 30
    @ObservationIgnored private var refreshTimer: Timer?
    @ObservationIgnored private var settingsObserver: NSObjectProtocol?
    @ObservationIgnored private var warningHandler: ((AIEvent) -> Void)?
    @ObservationIgnored private var latencySamplesCache: [ProviderLatencyTimeRange: CachedLatencySamples] = [:]
    @ObservationIgnored private var activitySamplesCache: [ProviderLatencyTimeRange: CachedActivitySamples] = [:]
    /// In-memory cache of the last snapshot per provider to avoid re-reading
    /// the entire JSONL file on every appendSnapshotIfNeeded call.
    @ObservationIgnored private var lastSnapshotByProvider: [String: ProviderQuotaSnapshot] = [:]
    @ObservationIgnored private var didSeedSnapshotCache = false
    /// Avoids redundant file I/O from ensureClaudeStatusLineInstalled on every refresh cycle.
    @ObservationIgnored private var claudeStatusLineInstalled = false

    private(set) var lastRefreshAt: Date?
    private(set) var lastErrorMessage: String?
    private(set) var isRefreshing = false
    private(set) var isClaudeStatusLineInstalled = false
    private(set) var providerSummaries: [UsageProviderSummary] = []
    private(set) var latencyProviders: [UsageLatencyProviderOverview] = []
    private(set) var latencyDashboard: UsageLatencyDashboard?
    private(set) var selectedLatencyProvider: String?
    var selectedLatencyTimeRange: ProviderLatencyTimeRange = .week {
        didSet {
            guard oldValue != selectedLatencyTimeRange else { return }
            refreshLatencySection()
        }
    }

    private init() {}

    private var shouldAutoRefresh: Bool {
        FeatureSettings.shared.isUsageMonitoringEnabled
            || FeatureSettings.shared.isClaudeStatusLineQuotaCaptureEnabled
            || FeatureSettings.shared.isUsageQuotaWarningsEnabled
    }

    func selectLatencyProvider(_ provider: String?) {
        guard selectedLatencyProvider != provider else { return }
        selectedLatencyProvider = provider
        refreshLatencySection()
    }

    func start() {
        guard settingsObserver == nil else { return }

        settingsObserver = NotificationCenter.default.addObserver(
            forName: .usageMonitoringSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSettingsChanged()
        }

        if shouldAutoRefresh {
            startRefreshTimerIfNeeded()
            refreshNow()
        }
    }

    func stop() {
        stopRefreshTimer()
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
            self.settingsObserver = nil
        }
    }

    func configureWarningHandler(_ handler: @escaping (AIEvent) -> Void) {
        warningHandler = handler
    }

    func refreshNow() {
        guard !isRefreshing else { return }
        isRefreshing = true

        let monitoringEnabled = FeatureSettings.shared.isUsageMonitoringEnabled
        let claudeStatusLineEnabled = FeatureSettings.shared.isClaudeStatusLineQuotaCaptureEnabled
        let warningsEnabled = FeatureSettings.shared.isUsageQuotaWarningsEnabled

        let snapshotsPath = Self.snapshotsFilePath
        let claudeSettingsPath = RuntimeIsolation.pathInHome(".claude/settings.json")
        let claudeHelperPath = RuntimeIsolation.pathInHome(".chau7/bin/\(ClaudeCodeStatusLineConfiguration.helperName)")
        // Snapshot main-mutated observables before hopping off-main (same
        // pattern as refreshLatencySection) — reading them inside the global
        // block raced UI writes.
        let latencyTimeRange = selectedLatencyTimeRange
        let currentLatencyProvider = selectedLatencyProvider

        DispatchQueue.global(qos: .utility).async {
            if claudeStatusLineEnabled {
                self.ensureClaudeStatusLineInstalled()
                self.captureLatestClaudeSnapshot()
            }
            if monitoringEnabled {
                self.captureLatestCodexSnapshot()
            }

            let snapshots = self.loadSnapshots(from: snapshotsPath)
            let cutoff = Date().addingTimeInterval(-600)
            let recentSnapshots = snapshots.filter { $0.capturedAt >= cutoff }
            let latestByProvider = Dictionary(grouping: snapshots, by: { $0.provider.lowercased() }).compactMapValues { group in
                group.max(by: { $0.capturedAt < $1.capturedAt })
            }
            // First-wins uniquing: lowercasing can collapse two provider rows
            // ("OpenAI"/"openai") into one key; don't crash the usage refresh.
            let recentConsumption = Dictionary(
                TelemetryStore.shared
                    .consumptionPerProvider(after: cutoff)
                    .map { ($0.provider.lowercased(), $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let latencySamples = self.loadLatencySamples(for: latencyTimeRange)
            let activitySamples = self.loadActivitySamples(for: latencyTimeRange)
            let interactionCounts = Dictionary(
                grouping: activitySamples,
                by: { $0.provider.lowercased() }
            ).mapValues(\.count)
            let latencyProviders = self.buildLatencyProviders(
                latencySamples: latencySamples,
                activitySamples: activitySamples
            )
            let selectedLatencyProvider = self.resolveSelectedLatencyProvider(
                current: currentLatencyProvider,
                available: latencyProviders.map(\.provider)
            )
            let latencyDashboard = selectedLatencyProvider.flatMap { provider in
                self.buildLatencyDashboard(
                    latencySamples: latencySamples,
                    activitySamples: activitySamples,
                    provider: provider,
                    interactionCount: interactionCounts[provider] ?? 0
                )
            }

            let providerOrder = ["codex", "claude"]
            let summaries = providerOrder.map { provider -> UsageProviderSummary in
                let latestSnapshot = latestByProvider[provider]
                let metrics = latestSnapshot.map {
                    ProviderQuotaEvaluator.metrics(
                        for: $0,
                        recentSnapshots: recentSnapshots.filter { $0.provider.caseInsensitiveCompare(provider) == .orderedSame }
                    )
                } ?? []
                let warnings = latestSnapshot.map {
                    ProviderQuotaEvaluator.warnings(
                        for: $0,
                        recentSnapshots: recentSnapshots.filter { $0.provider.caseInsensitiveCompare(provider) == .orderedSame }
                    )
                } ?? []
                let statusMessage = self.statusMessage(
                    for: provider,
                    latestSnapshot: latestSnapshot,
                    claudeStatusLineEnabled: claudeStatusLineEnabled
                )

                return UsageProviderSummary(
                    provider: provider,
                    displayName: Self.displayName(for: provider),
                    latestSnapshot: latestSnapshot,
                    recentRunConsumption: recentConsumption[provider],
                    windowMetrics: metrics,
                    activeWarnings: warnings,
                    statusMessage: statusMessage
                )
            }

            let claudeInstalled = self.fileManager.fileExists(atPath: claudeSettingsPath)
                && ((try? Data(contentsOf: URL(fileURLWithPath: claudeSettingsPath)))
                    .map { ClaudeCodeStatusLineConfiguration.statusLineIncludesHelper(in: $0, helperPath: claudeHelperPath) } ?? false)

            let warningEvents = monitoringEnabled && warningsEnabled ? self.warningEvents(for: summaries) : []

            DispatchQueue.main.async {
                self.providerSummaries = summaries
                self.isClaudeStatusLineInstalled = claudeInstalled
                self.lastRefreshAt = Date()
                self.lastErrorMessage = nil
                self.isRefreshing = false
                self.latencyProviders = latencyProviders
                self.selectedLatencyProvider = selectedLatencyProvider
                self.latencyDashboard = latencyDashboard
                warningEvents.forEach { self.warningHandler?($0) }
            }
        }
    }

    func installClaudeStatusLineCapture() {
        FeatureSettings.shared.isClaudeStatusLineQuotaCaptureEnabled = true
        refreshNow()
    }

    func uninstallClaudeStatusLineCapture() {
        let settingsPath = RuntimeIsolation.pathInHome(".claude/settings.json")
        let originalPath = Self.claudeStatusLineOriginalPath
        let helperPath = RuntimeIsolation.pathInHome(".chau7/bin/\(ClaudeCodeStatusLineConfiguration.helperName)")

        let url = URL(fileURLWithPath: settingsPath)
        guard let currentData = try? Data(contentsOf: url) else {
            // The flag flips off but the helper hook stays wired into
            // Claude's settings — say so instead of pretending success.
            lastErrorMessage = "Failed to uninstall Claude statusLine: could not read \(settingsPath); the hook may still be installed"
            FeatureSettings.shared.isClaudeStatusLineQuotaCaptureEnabled = false
            refreshNow()
            return
        }
        guard ClaudeCodeStatusLineConfiguration.statusLineIncludesHelper(in: currentData, helperPath: helperPath) else {
            FeatureSettings.shared.isClaudeStatusLineQuotaCaptureEnabled = false
            refreshNow()
            return
        }

        let backupData = try? Data(contentsOf: URL(fileURLWithPath: originalPath))
        guard let restored = ClaudeCodeStatusLineConfiguration.restoreStatusLine(
            in: currentData,
            backupStatusLineData: backupData
        ) else {
            lastErrorMessage = "Failed to uninstall Claude statusLine: settings.json could not be rewritten; the hook may still be installed"
            FeatureSettings.shared.isClaudeStatusLineQuotaCaptureEnabled = false
            refreshNow()
            return
        }

        do {
            try restored.write(to: url, options: .atomic)
            try? fileManager.removeItem(atPath: originalPath)
        } catch {
            lastErrorMessage = "Failed to uninstall Claude statusLine: \(error.localizedDescription)"
        }

        FeatureSettings.shared.isClaudeStatusLineQuotaCaptureEnabled = false
        refreshNow()
    }

    private func handleSettingsChanged() {
        if shouldAutoRefresh {
            startRefreshTimerIfNeeded()
            refreshNow()
        } else {
            stopRefreshTimer()
        }
    }

    private func startRefreshTimerIfNeeded() {
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refreshNow()
        }
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func refreshLatencySection() {
        let timeRange = selectedLatencyTimeRange
        let selectedProvider = selectedLatencyProvider

        DispatchQueue.global(qos: .userInitiated).async {
            let latencySamples = self.loadLatencySamples(for: timeRange)
            let activitySamples = self.loadActivitySamples(for: timeRange)
            let interactionCounts = Dictionary(
                grouping: activitySamples,
                by: { $0.provider.lowercased() }
            ).mapValues(\.count)
            let latencyProviders = self.buildLatencyProviders(
                latencySamples: latencySamples,
                activitySamples: activitySamples
            )
            let resolvedProvider = self.resolveSelectedLatencyProvider(
                current: selectedProvider,
                available: latencyProviders.map(\.provider)
            )
            let latencyDashboard = resolvedProvider.flatMap { provider in
                self.buildLatencyDashboard(
                    latencySamples: latencySamples,
                    activitySamples: activitySamples,
                    provider: provider,
                    interactionCount: interactionCounts[provider] ?? 0
                )
            }

            DispatchQueue.main.async {
                self.latencyProviders = latencyProviders
                self.selectedLatencyProvider = resolvedProvider
                self.latencyDashboard = latencyDashboard
            }
        }
    }

    private func ensureClaudeStatusLineInstalled() {
        if claudeStatusLineInstalled { return }
        let helperPath = RuntimeIsolation.pathInHome(".chau7/bin/\(ClaudeCodeStatusLineConfiguration.helperName)")
        let settingsPath = RuntimeIsolation.pathInHome(".claude/settings.json")
        let settingsURL = URL(fileURLWithPath: settingsPath)
        let backupURL = URL(fileURLWithPath: Self.claudeStatusLineOriginalPath)

        do {
            try fileManager.createDirectory(
                at: RuntimeIsolation.urlInHome(".chau7/bin"),
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: RuntimeIsolation.urlInHome(".chau7/usage"),
                withIntermediateDirectories: true
            )

            let script = ClaudeCodeStatusLineConfiguration.helperScript(
                latestStatusPayloadPath: Self.claudeStatusLineLatestPayloadPath,
                originalStatusLinePath: Self.claudeStatusLineOriginalPath
            )
            try script.write(to: URL(fileURLWithPath: helperPath), atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperPath)

            let claudeDir = (settingsPath as NSString).deletingLastPathComponent
            try fileManager.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)

            let existingData = (try? Data(contentsOf: settingsURL)) ?? Data("{}".utf8)
            if !ClaudeCodeStatusLineConfiguration.statusLineIncludesHelper(in: existingData, helperPath: helperPath),
               let backupData = ClaudeCodeStatusLineConfiguration.currentStatusLineData(in: existingData) {
                try backupData.write(to: backupURL, options: .atomic)
            }

            guard let updated = ClaudeCodeStatusLineConfiguration.upsertStatusLine(
                in: existingData,
                helperPath: helperPath
            ) else {
                throw NSError(domain: "UsageMonitor", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Unable to update Claude settings.json"
                ])
            }
            try updated.write(to: settingsURL, options: .atomic)
            claudeStatusLineInstalled = true
        } catch {
            DispatchQueue.main.async {
                self.lastErrorMessage = "Failed to install Claude statusLine: \(error.localizedDescription)"
            }
        }
    }

    private func captureLatestClaudeSnapshot() {
        let payloadURL = URL(fileURLWithPath: Self.claudeStatusLineLatestPayloadPath)
        guard let data = try? Data(contentsOf: payloadURL) else { return }

        let capturedAt = ((try? payloadURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate) ?? Date()

        guard let snapshot = ClaudeCodeStatusLineConfiguration.quotaSnapshot(
            fromStatusJSON: data,
            capturedAt: capturedAt,
            rawSourceRef: payloadURL.path
        ) else {
            return
        }

        appendSnapshotIfNeeded(snapshot)
    }

    private func captureLatestCodexSnapshot() {
        guard let latestRollout = latestCodexRolloutFile(),
              let text = try? String(contentsOf: latestRollout, encoding: .utf8),
              var snapshot = CodexRolloutParser.latestQuotaSnapshot(in: text, rawSourceRef: latestRollout.path) else {
            return
        }

        snapshot = ProviderQuotaSnapshot(
            provider: snapshot.provider,
            capturedAt: snapshot.capturedAt,
            source: snapshot.source,
            planType: snapshot.planType,
            credits: snapshot.credits,
            rawSourceRef: latestRollout.path,
            windows: snapshot.windows
        )
        appendSnapshotIfNeeded(snapshot)
    }

    private func loadLatencySamples(for timeRange: ProviderLatencyTimeRange) -> [ProviderLatencySample] {
        let now = Date()
        if let cached = latencySamplesCache[timeRange],
           now.timeIntervalSince(cached.loadedAt) < Self.latencyCacheTTL(for: timeRange) {
            return cached.samples
        }

        let after = timeRange.startDate(now: now)
        let proxySamples = ProxyAnalyticsStore.shared.latencySamples(after: after)
        let cliSamples = TelemetryStore.shared.latencySamples(after: after)
        let samples = (proxySamples + cliSamples).sorted { $0.timestamp < $1.timestamp }
        latencySamplesCache[timeRange] = CachedLatencySamples(loadedAt: now, samples: samples)
        return samples
    }

    private func loadActivitySamples(for timeRange: ProviderLatencyTimeRange) -> [ProviderActivitySample] {
        let now = Date()
        if let cached = activitySamplesCache[timeRange],
           now.timeIntervalSince(cached.loadedAt) < Self.latencyCacheTTL(for: timeRange) {
            return cached.samples
        }

        let after = timeRange.startDate(now: Date())
        let runSamples = TelemetryStore.shared.listRuns(filter: TelemetryRunFilter(after: after, limit: after == nil ? 2000 : nil))
            .filter { $0.endedAt != nil }
            .map { run in
                ProviderActivitySample(
                    provider: run.provider.lowercased(),
                    timestamp: run.startedAt,
                    sourceKind: "completed_run"
                )
            }
        let apiSamples = ProxyAnalyticsStore.shared.activitySamples(after: after)
        let samples = (runSamples + apiSamples).sorted { $0.timestamp < $1.timestamp }
        activitySamplesCache[timeRange] = CachedActivitySamples(loadedAt: now, samples: samples)
        return samples
    }

    private func buildLatencyProviders(
        latencySamples: [ProviderLatencySample],
        activitySamples: [ProviderActivitySample]
    ) -> [UsageLatencyProviderOverview] {
        let groupedLatency = Dictionary(grouping: latencySamples, by: { $0.provider.lowercased() })
        let groupedActivity = Dictionary(grouping: activitySamples, by: { $0.provider.lowercased() })
        let providers = Set(groupedLatency.keys).union(groupedActivity.keys)

        return providers.compactMap { provider in
            let interactionCount = groupedActivity[provider]?.count ?? 0
            let sampledLatencyCount = groupedLatency[provider]?.count ?? 0
            guard interactionCount > 0 || sampledLatencyCount > 0 else { return nil }

            return UsageLatencyProviderOverview(
                provider: provider,
                displayName: Self.displayName(for: provider),
                sampledLatencyCount: sampledLatencyCount,
                interactionCount: interactionCount
            )
        }
        .sorted { lhs, rhs in
            if lhs.interactionCount != rhs.interactionCount {
                return lhs.interactionCount > rhs.interactionCount
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private func resolveSelectedLatencyProvider(current: String?, available: [String]) -> String? {
        guard !available.isEmpty else { return nil }
        if let current, available.contains(current) {
            return current
        }
        for preferred in ["codex", "claude", "anthropic", "openai", "gemini"] where available.contains(preferred) {
            return preferred
        }
        return available.first
    }

    private func buildLatencyDashboard(
        latencySamples: [ProviderLatencySample],
        activitySamples: [ProviderActivitySample],
        provider: String,
        interactionCount: Int
    ) -> UsageLatencyDashboard? {
        let providerLatency = latencySamples.filter {
            $0.provider.caseInsensitiveCompare(provider) == .orderedSame
        }
        let filteredActivity = activitySamples.filter {
            $0.provider.caseInsensitiveCompare(provider) == .orderedSame
        }
        guard !providerLatency.isEmpty || !filteredActivity.isEmpty else { return nil }
        let availableMetricKinds = Array(Set(providerLatency.map(\.metricKind))).sorted {
            Self.metricOrder($0) < Self.metricOrder($1)
        }

        return UsageLatencyDashboard(
            provider: provider,
            displayName: Self.displayName(for: provider),
            metricKinds: availableMetricKinds,
            aggregate: ProviderLatencyAnalytics.aggregate(samples: providerLatency),
            sampledCount: providerLatency.count,
            totalInteractionCount: interactionCount,
            dailyBuckets: ProviderLatencyAnalytics.bucketed(samples: providerLatency, by: .day),
            weekdayBuckets: ProviderLatencyAnalytics.bucketed(samples: providerLatency, by: .weekday),
            periodBuckets: ProviderLatencyAnalytics.bucketed(samples: providerLatency, by: .periodOfDay),
            hourBuckets: ProviderLatencyAnalytics.bucketed(samples: providerLatency, by: .hourOfDay),
            activityDailyBuckets: ProviderLatencyAnalytics.activityBucketed(samples: filteredActivity, by: .day),
            activityWeekdayBuckets: ProviderLatencyAnalytics.activityBucketed(samples: filteredActivity, by: .weekday),
            activityPeriodBuckets: ProviderLatencyAnalytics.activityBucketed(samples: filteredActivity, by: .periodOfDay),
            activityHourBuckets: ProviderLatencyAnalytics.activityBucketed(samples: filteredActivity, by: .hourOfDay)
        )
    }

    private func latestCodexRolloutFile() -> URL? {
        let sessionsRoot = RuntimeIsolation.urlInHome(".codex/sessions")
        let dayDirectories = recentCodexDayDirectories(root: sessionsRoot, limit: 14)

        var bestURL: URL?
        var bestDate = Date.distantPast

        for dayDirectory in dayDirectories {
            guard let files = try? fileManager.contentsOfDirectory(
                at: dayDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
                let modifiedAt = values?.contentModificationDate ?? .distantPast
                if modifiedAt > bestDate {
                    bestDate = modifiedAt
                    bestURL = file
                }
            }
        }

        return bestURL
    }

    private func recentCodexDayDirectories(root: URL, limit: Int) -> [URL] {
        guard let years = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter({ $0.lastPathComponent.allSatisfy(\.isNumber) })
            .sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) else {
            return []
        }

        var results: [URL] = []
        for year in years {
            guard let months = try? fileManager.contentsOfDirectory(at: year, includingPropertiesForKeys: nil)
                .filter({ $0.lastPathComponent.allSatisfy(\.isNumber) })
                .sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) else {
                continue
            }
            for month in months {
                guard let days = try? fileManager.contentsOfDirectory(at: month, includingPropertiesForKeys: nil)
                    .filter({ $0.lastPathComponent.allSatisfy(\.isNumber) })
                    .sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) else {
                    continue
                }
                for day in days {
                    results.append(day)
                    if results.count >= limit {
                        return results
                    }
                }
            }
        }
        return results
    }

    private func loadSnapshots(from path: String) -> [ProviderQuotaSnapshot] {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return content
            .split(separator: "\n")
            .compactMap { parseSnapshotLine(String($0)) }
            .sorted { $0.capturedAt < $1.capturedAt }
    }

    private func appendSnapshotIfNeeded(_ snapshot: ProviderQuotaSnapshot) {
        let providerKey = snapshot.provider.lowercased()

        // Seed the in-memory cache from a single file read covering all providers,
        // rather than re-parsing the whole snapshots file once per provider seen.
        // loadSnapshots is sorted ascending by capturedAt, so the last write wins.
        if !didSeedSnapshotCache {
            didSeedSnapshotCache = true
            for existing in loadSnapshots(from: Self.snapshotsFilePath) {
                lastSnapshotByProvider[existing.provider.lowercased()] = existing
            }
        }

        if let existing = lastSnapshotByProvider[providerKey],
           existing.windows == snapshot.windows, existing.planType == snapshot.planType {
            return
        }

        let line = serialize(snapshot: snapshot) + "\n"
        let targetURL = URL(fileURLWithPath: Self.snapshotsFilePath)
        do {
            try fileManager.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: targetURL.path),
               let handle = try? FileHandle(forWritingTo: targetURL) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            } else {
                try line.write(to: targetURL, atomically: true, encoding: .utf8)
            }
            lastSnapshotByProvider[providerKey] = snapshot
        } catch {
            DispatchQueue.main.async {
                self.lastErrorMessage = "Failed to store usage snapshot: \(error.localizedDescription)"
            }
        }
    }

    private func parseSnapshotLine(_ line: String) -> ProviderQuotaSnapshot? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let provider = json["provider"] as? String,
              let capturedAt = Self.parseDate(json["capturedAt"]),
              let source = json["source"] as? String,
              let windowsArray = json["windows"] as? [[String: Any]] else {
            return nil
        }

        let windows = windowsArray.compactMap { windowJSON -> ProviderQuotaWindowSnapshot? in
            guard let id = windowJSON["id"] as? String,
                  let usedPercent = Self.doubleValue(windowJSON["usedPercent"]) else {
                return nil
            }
            return ProviderQuotaWindowSnapshot(
                id: id,
                usedPercent: usedPercent,
                windowMinutes: Self.intValue(windowJSON["windowMinutes"]),
                resetsAt: Self.parseDate(windowJSON["resetsAt"])
            )
        }
        guard !windows.isEmpty else { return nil }

        return ProviderQuotaSnapshot(
            provider: provider,
            capturedAt: capturedAt,
            source: source,
            planType: json["planType"] as? String,
            credits: Self.doubleValue(json["credits"]),
            rawSourceRef: json["rawSourceRef"] as? String,
            windows: windows
        )
    }

    private func serialize(snapshot: ProviderQuotaSnapshot) -> String {
        let windows = snapshot.windows.map { window in
            var payload: [String: Any] = [
                "id": window.id,
                "usedPercent": window.usedPercent
            ]
            if let windowMinutes = window.windowMinutes {
                payload["windowMinutes"] = windowMinutes
            }
            if let resetsAt = window.resetsAt {
                payload["resetsAt"] = Int(resetsAt.timeIntervalSince1970)
            }
            return payload
        }
        var payload: [String: Any] = [
            "provider": snapshot.provider,
            "capturedAt": Self.isoFormatter.string(from: snapshot.capturedAt),
            "source": snapshot.source,
            "windows": windows
        ]
        if let planType = snapshot.planType {
            payload["planType"] = planType
        }
        if let credits = snapshot.credits {
            payload["credits"] = credits
        }
        if let rawSourceRef = snapshot.rawSourceRef {
            payload["rawSourceRef"] = rawSourceRef
        }
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(data: data ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
    }

    private func warningEvents(for summaries: [UsageProviderSummary]) -> [AIEvent] {
        summaries.reduce(into: [AIEvent]()) { result, summary in
            guard let latestSnapshot = summary.latestSnapshot,
                  Date().timeIntervalSince(latestSnapshot.capturedAt) <= 15 * 60 else {
                return
            }
            for warning in summary.activeWarnings {
                guard Self.shouldEmitWarning(warning) else { continue }
                Self.markWarningEmitted(warning)
                result.append(Self.warningEvent(for: warning, displayName: summary.displayName))
            }
        }
    }

    private func statusMessage(
        for provider: String,
        latestSnapshot: ProviderQuotaSnapshot?,
        claudeStatusLineEnabled: Bool
    ) -> String? {
        if latestSnapshot != nil { return nil }
        switch provider {
        case "claude":
            return claudeStatusLineEnabled
                ? "Waiting for Claude Code statusLine quota data."
                : "Enable Claude statusLine capture to collect quota windows."
        case "codex":
            return FeatureSettings.shared.isUsageMonitoringEnabled
                ? "Waiting for recent Codex rollout quota data."
                : "Enable usage monitoring to capture Codex quota snapshots."
        default:
            return nil
        }
    }

    private static func warningEvent(for warning: ProviderQuotaWarning, displayName: String) -> AIEvent {
        let windowLabel = warning.window.windowMinutes.map(Self.windowLabel(minutes:)) ?? warning.window.id
        let resetSuffix: String
        if let resetsAt = warning.window.resetsAt {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            resetSuffix = " Reset at \(formatter.string(from: resetsAt))."
        } else {
            resetSuffix = ""
        }

        let message: String
        switch warning.kind {
        case .unsustainablePace:
            message = "\(displayName) \(windowLabel) usage is burning faster than the remaining window can sustain.\(resetSuffix)"
        case .remaining20:
            message = "\(displayName) \(windowLabel) quota is down to 20% remaining.\(resetSuffix)"
        case .remaining10:
            message = "\(displayName) \(windowLabel) quota is down to 10% remaining.\(resetSuffix)"
        case .remaining5:
            message = "\(displayName) \(windowLabel) quota is down to 5% remaining.\(resetSuffix)"
        }

        return AIEvent(
            source: .app,
            type: "token_threshold",
            tool: displayName,
            message: message,
            ts: DateFormatters.nowISO8601(),
            producer: "usage_monitor",
            reliability: .authoritative
        )
    }

    private static func shouldEmitWarning(_ warning: ProviderQuotaWarning) -> Bool {
        let key = warning.id
        return !issuedWarningIDs().contains(key)
    }

    private static func markWarningEmitted(_ warning: ProviderQuotaWarning) {
        var issued = issuedWarningIDs()
        issued.insert(warning.id)
        UserDefaults.standard.set(Array(issued), forKey: "usage.monitor.issuedWarnings")
    }

    private static func issuedWarningIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "usage.monitor.issuedWarnings") ?? [])
    }

    private static func displayName(for provider: String) -> String {
        switch provider.lowercased() {
        case "claude":
            return "Claude Code"
        case "codex":
            return "Codex"
        case "anthropic":
            return "Anthropic API"
        case "openai":
            return "OpenAI API"
        case "gemini":
            return "Gemini API"
        default:
            return provider.capitalized
        }
    }

    private static func metricOrder(_ metricKind: ProviderLatencyMetricKind) -> Int {
        switch metricKind {
        case .firstResponse:
            return 0
        case .apiRequest:
            return 1
        }
    }

    private static func latencyCacheTTL(for timeRange: ProviderLatencyTimeRange) -> TimeInterval {
        switch timeRange {
        case .allTime:
            return 300
        case .quarter:
            return 120
        case .month:
            return 60
        case .today, .week, .twoWeeks:
            return 15
        }
    }

    private static func windowLabel(minutes: Int) -> String {
        switch minutes {
        case 300:
            return "5h"
        case 10080:
            return "7d"
        default:
            if minutes.isMultiple(of: 60) {
                return "\(minutes / 60)h"
            }
            return "\(minutes)m"
        }
    }

    private static func parseDate(_ raw: Any?) -> Date? {
        switch raw {
        case let value as NSNumber:
            return Date(timeIntervalSince1970: value.doubleValue)
        case let value as String:
            return isoFormatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        default:
            return nil
        }
    }

    private static func doubleValue(_ raw: Any?) -> Double? {
        switch raw {
        case let value as NSNumber:
            return value.doubleValue
        case let value as String:
            return Double(value)
        default:
            return nil
        }
    }

    private static func intValue(_ raw: Any?) -> Int? {
        switch raw {
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value)
        default:
            return nil
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let snapshotsFilePath = RuntimeIsolation.pathInHome(".chau7/usage/provider-quotas.jsonl")
    private static let claudeStatusLineLatestPayloadPath = RuntimeIsolation.pathInHome(".chau7/usage/claude-statusline-latest.json")
    private static let claudeStatusLineOriginalPath = RuntimeIsolation.pathInHome(".chau7/usage/claude-statusline-original.json")
}
