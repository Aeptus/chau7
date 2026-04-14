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
    let metrics: [UsageLatencyMetricOverview]

    var id: String {
        provider
    }
}

struct UsageLatencyDashboard {
    let provider: String
    let displayName: String
    let metricKind: ProviderLatencyMetricKind
    let aggregate: ProviderLatencyAggregate
    let dailyBuckets: [ProviderLatencyBucketPoint]
    let weekdayBuckets: [ProviderLatencyBucketPoint]
    let periodBuckets: [ProviderLatencyBucketPoint]
    let hourBuckets: [ProviderLatencyBucketPoint]
}

private struct CachedLatencySamples {
    let loadedAt: Date
    let samples: [ProviderLatencySample]
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

    private(set) var lastRefreshAt: Date?
    private(set) var lastErrorMessage: String?
    private(set) var isRefreshing = false
    private(set) var isClaudeStatusLineInstalled = false
    private(set) var providerSummaries: [UsageProviderSummary] = []
    private(set) var latencyProviders: [UsageLatencyProviderOverview] = []
    private(set) var latencyDashboard: UsageLatencyDashboard?
    private(set) var selectedLatencyProvider: String?
    private(set) var selectedLatencyMetricKind: ProviderLatencyMetricKind?
    var selectedLatencyTimeRange: ProviderLatencyTimeRange = .week {
        didSet {
            guard oldValue != selectedLatencyTimeRange else { return }
            refreshNow()
        }
    }

    private init() {}

    func selectLatencyProvider(_ provider: String?) {
        guard selectedLatencyProvider != provider else { return }
        selectedLatencyProvider = provider
        refreshNow()
    }

    func selectLatencyMetricKind(_ metricKind: ProviderLatencyMetricKind?) {
        guard selectedLatencyMetricKind != metricKind else { return }
        selectedLatencyMetricKind = metricKind
        refreshNow()
    }

    func start() {
        guard refreshTimer == nil else { return }

        settingsObserver = NotificationCenter.default.addObserver(
            forName: .usageMonitoringSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSettingsChanged()
        }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refreshNow()
        }
        refreshNow()
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
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
            let recentConsumption = Dictionary(
                uniqueKeysWithValues: TelemetryStore.shared
                    .consumptionPerProvider(after: cutoff)
                    .map { ($0.provider.lowercased(), $0) }
            )
            let latencySamples = self.loadLatencySamples(for: self.selectedLatencyTimeRange)
            let latencyProviders = self.buildLatencyProviders(from: latencySamples)
            let selectedLatencyProvider = self.resolveSelectedLatencyProvider(
                current: self.selectedLatencyProvider,
                available: latencyProviders.map(\.provider)
            )
            let selectedLatencyMetricKind = self.resolveSelectedLatencyMetricKind(
                current: self.selectedLatencyMetricKind,
                provider: selectedLatencyProvider,
                samples: latencySamples
            )
            let latencyDashboard = selectedLatencyProvider.flatMap { provider in
                selectedLatencyMetricKind.flatMap { kind in
                    self.buildLatencyDashboard(samples: latencySamples, provider: provider, metricKind: kind)
                }
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
                self.selectedLatencyMetricKind = selectedLatencyMetricKind
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
        refreshNow()
    }

    private func ensureClaudeStatusLineInstalled() {
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

    private func buildLatencyProviders(from samples: [ProviderLatencySample]) -> [UsageLatencyProviderOverview] {
        Dictionary(grouping: samples, by: { $0.provider.lowercased() })
            .compactMap { provider, providerSamples -> UsageLatencyProviderOverview? in
                let metrics = Dictionary(grouping: providerSamples, by: \.metricKind)
                    .compactMap { metricKind, metricSamples -> UsageLatencyMetricOverview? in
                        guard let aggregate = ProviderLatencyAnalytics.aggregate(samples: metricSamples) else { return nil }
                        return UsageLatencyMetricOverview(metricKind: metricKind, aggregate: aggregate)
                    }
                    .sorted { lhs, rhs in
                        Self.metricOrder(lhs.metricKind) < Self.metricOrder(rhs.metricKind)
                    }

                guard !metrics.isEmpty else { return nil }
                return UsageLatencyProviderOverview(
                    provider: provider,
                    displayName: Self.displayName(for: provider),
                    metrics: metrics
                )
            }
            .sorted { lhs, rhs in
                if lhs.metrics.count != rhs.metrics.count {
                    return lhs.metrics.count > rhs.metrics.count
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

    private func resolveSelectedLatencyMetricKind(
        current: ProviderLatencyMetricKind?,
        provider: String?,
        samples: [ProviderLatencySample]
    ) -> ProviderLatencyMetricKind? {
        guard let provider else { return nil }
        let availableKinds = Array(Set(samples
                .filter { $0.provider.caseInsensitiveCompare(provider) == .orderedSame }
                .map(\.metricKind)))
            .sorted { Self.metricOrder($0) < Self.metricOrder($1) }
        guard !availableKinds.isEmpty else { return nil }
        if let current, availableKinds.contains(current) {
            return current
        }
        return availableKinds.first
    }

    private func buildLatencyDashboard(
        samples: [ProviderLatencySample],
        provider: String,
        metricKind: ProviderLatencyMetricKind
    ) -> UsageLatencyDashboard? {
        let filtered = samples.filter {
            $0.provider.caseInsensitiveCompare(provider) == .orderedSame && $0.metricKind == metricKind
        }
        guard let aggregate = ProviderLatencyAnalytics.aggregate(samples: filtered) else { return nil }
        return UsageLatencyDashboard(
            provider: provider,
            displayName: Self.displayName(for: provider),
            metricKind: metricKind,
            aggregate: aggregate,
            dailyBuckets: ProviderLatencyAnalytics.bucketed(samples: filtered, by: .day),
            weekdayBuckets: ProviderLatencyAnalytics.bucketed(samples: filtered, by: .weekday),
            periodBuckets: ProviderLatencyAnalytics.bucketed(samples: filtered, by: .periodOfDay),
            hourBuckets: ProviderLatencyAnalytics.bucketed(samples: filtered, by: .hourOfDay)
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
        let existing = loadSnapshots(from: Self.snapshotsFilePath)
            .last { $0.provider.caseInsensitiveCompare(snapshot.provider) == .orderedSame }

        if let existing, existing.windows == snapshot.windows, existing.planType == snapshot.planType {
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
