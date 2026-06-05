import Foundation
import Chau7Core

struct IncidentBreadcrumb: Codable, Equatable {
    enum Kind: String, Codable {
        case appRecovery = "app_recovery"
        case memoryPressure = "memory_pressure"
        case proxyRequestHighWater = "proxy_request_high_water"
        case restorePayload = "restore_payload"
    }

    enum Severity: String, Codable {
        case info
        case warning
        case critical
    }

    let schemaVersion: Int
    let id: UUID
    let timestamp: Date
    let kind: Kind
    let severity: Severity
    let message: String
    let metadata: [String: String]

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        kind: Kind,
        severity: Severity,
        message: String,
        metadata: [String: String]
    ) {
        self.schemaVersion = 1
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.severity = severity
        self.message = message
        self.metadata = metadata
    }
}

struct RestorePayloadBreadcrumbSnapshot: Equatable {
    let reason: String
    let windowCount: Int
    let tabCount: Int
    let paneCount: Int
    let legacyPayloadBytes: Int
    let multiWindowPayloadBytes: Int
    let largestTabPayloadBytes: Int
    let largestTabID: String?
    let largestTabTitle: String?
    let largestPanePayloadBytes: Int
    let largestPaneID: String?
    let largestPaneDirectory: String?

    var totalUserDefaultsBytes: Int {
        legacyPayloadBytes + multiWindowPayloadBytes
    }

    var metadata: [String: String] {
        var values: [String: String] = [
            "reason": reason,
            "windowCount": "\(windowCount)",
            "tabCount": "\(tabCount)",
            "paneCount": "\(paneCount)",
            "legacyPayloadBytes": "\(legacyPayloadBytes)",
            "multiWindowPayloadBytes": "\(multiWindowPayloadBytes)",
            "totalUserDefaultsBytes": "\(totalUserDefaultsBytes)",
            "largestTabPayloadBytes": "\(largestTabPayloadBytes)",
            "largestPanePayloadBytes": "\(largestPanePayloadBytes)"
        ]
        if let largestTabID {
            values["largestTabID"] = largestTabID
        }
        if let largestTabTitle, !largestTabTitle.isEmpty {
            values["largestTabTitle"] = String(largestTabTitle.prefix(80))
        }
        if let largestPaneID {
            values["largestPaneID"] = largestPaneID
        }
        if let largestPaneDirectory, !largestPaneDirectory.isEmpty {
            values["largestPaneDirectory"] = String(largestPaneDirectory.prefix(120))
        }
        return values
    }
}

final class IncidentBreadcrumbStore {
    static let shared = IncidentBreadcrumbStore()

    private static let reportedMemoryPressureIncidentKey = "com.chau7.lastReportedMemoryPressureIncidentID"
    private static let restorePayloadThresholdBytes = 1_000_000
    private static let restorePayloadRecordInterval: TimeInterval = 5 * 60
    private static let restorePayloadChangeThresholdBytes = 256 * 1024
    private static let proxyRequestHighWaterThresholdBytes = 512 * 1024
    private static let memoryPressureRecordInterval: TimeInterval = 60
    private static let memoryPressureResidentChangeThresholdBytes: UInt64 = 256 * 1024 * 1024
    private static let maxLogBytes = 256 * 1024

    private let queue = DispatchQueue(label: "com.chau7.incident-breadcrumbs", qos: .utility)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let fileManager: FileManager
    private let directoryProvider: () -> URL
    private let defaults: UserDefaults
    private let now: () -> Date
    private let makeID: () -> UUID

    private var lastRestoreSnapshot: RestorePayloadBreadcrumbSnapshot?
    private var lastRestoreBreadcrumbAt: Date?
    private var lastRestoreBreadcrumbBytes = 0
    private var proxyRequestHighWaterBytes = 0
    private var lastMemoryBreadcrumbAtBySeverity: [IncidentBreadcrumb.Severity: Date] = [:]
    private var lastMemoryBreadcrumbResidentBytesBySeverity: [IncidentBreadcrumb.Severity: UInt64] = [:]

    init(
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard,
        directoryProvider: @escaping () -> URL = {
            RuntimeIsolation.appSupportDirectory(named: "Chau7")
                .appendingPathComponent("Incidents", isDirectory: true)
        },
        now: @escaping () -> Date = Date.init,
        makeID: @escaping () -> UUID = UUID.init
    ) {
        self.fileManager = fileManager
        self.defaults = defaults
        self.directoryProvider = directoryProvider
        self.now = now
        self.makeID = makeID
        queue.setSpecific(key: queueKey, value: 1)
    }

    @discardableResult
    func record(
        kind: IncidentBreadcrumb.Kind,
        severity: IncidentBreadcrumb.Severity,
        message: String,
        metadata: [String: String],
        synchronously: Bool = false
    ) -> IncidentBreadcrumb {
        let breadcrumb = IncidentBreadcrumb(
            id: makeID(),
            timestamp: now(),
            kind: kind,
            severity: severity,
            message: message,
            metadata: metadata
        )
        perform(synchronously: synchronously) {
            self.append(breadcrumb)
        }
        return breadcrumb
    }

    func recordRestorePayloadSnapshot(_ snapshot: RestorePayloadBreadcrumbSnapshot) {
        perform(synchronously: false) {
            self.lastRestoreSnapshot = snapshot

            guard snapshot.totalUserDefaultsBytes >= Self.restorePayloadThresholdBytes else {
                return
            }

            let currentTime = self.now()
            let elapsed = self.lastRestoreBreadcrumbAt.map { currentTime.timeIntervalSince($0) } ?? .infinity
            let byteDelta = abs(snapshot.totalUserDefaultsBytes - self.lastRestoreBreadcrumbBytes)
            guard elapsed >= Self.restorePayloadRecordInterval
                || byteDelta >= Self.restorePayloadChangeThresholdBytes else {
                return
            }

            self.lastRestoreBreadcrumbAt = currentTime
            self.lastRestoreBreadcrumbBytes = snapshot.totalUserDefaultsBytes
            let breadcrumb = IncidentBreadcrumb(
                id: self.makeID(),
                timestamp: currentTime,
                kind: .restorePayload,
                severity: .warning,
                message: "Large restore payload observed during autosave",
                metadata: snapshot.metadata
            )
            self.append(breadcrumb)
        }
    }

    func recordMemoryPressure(
        level: IncidentBreadcrumb.Severity,
        residentBytes: UInt64,
        physicalBytes: UInt64,
        reclaimedBytes: Int? = nil,
        synchronously: Bool
    ) {
        perform(synchronously: synchronously) {
            let currentTime = self.now()
            let elapsed = self.lastMemoryBreadcrumbAtBySeverity[level]
                .map { currentTime.timeIntervalSince($0) } ?? .infinity
            let residentDelta = self.lastMemoryBreadcrumbResidentBytesBySeverity[level]
                .map { previous -> UInt64 in
                    residentBytes > previous ? residentBytes - previous : previous - residentBytes
                } ?? .max
            guard elapsed >= Self.memoryPressureRecordInterval
                || residentDelta >= Self.memoryPressureResidentChangeThresholdBytes else {
                return
            }
            self.lastMemoryBreadcrumbAtBySeverity[level] = currentTime
            self.lastMemoryBreadcrumbResidentBytesBySeverity[level] = residentBytes

            var metadata: [String: String] = [
                "residentBytes": "\(residentBytes)",
                "residentMB": "\(residentBytes / (1024 * 1024))",
                "physicalBytes": "\(physicalBytes)",
                "physicalMB": "\(physicalBytes / (1024 * 1024))"
            ]
            if physicalBytes > 0 {
                let ratioPercent = Int((Double(residentBytes) / Double(physicalBytes)) * 100)
                metadata["residentPhysicalPercent"] = "\(ratioPercent)"
            }
            if let snapshot = self.lastRestoreSnapshot {
                metadata.merge(snapshot.metadata.mapKeys { "restore.\($0)" }) { current, _ in current }
            }
            metadata["proxyRequestHighWaterBytes"] = "\(self.proxyRequestHighWaterBytes)"
            if let reclaimedBytes, reclaimedBytes > 0 {
                metadata["reclaimedBytes"] = "\(reclaimedBytes)"
                metadata["reclaimedMB"] = "\(reclaimedBytes / (1024 * 1024))"
            }

            let breadcrumb = IncidentBreadcrumb(
                id: self.makeID(),
                timestamp: currentTime,
                kind: .memoryPressure,
                severity: level,
                message: level == .critical ? "Critical memory pressure" : "Memory pressure warning",
                metadata: metadata
            )
            self.append(breadcrumb)
        }
    }

    func recordProxyOutputIfHighWater(_ message: String) {
        guard let requestBytes = Self.requestLength(fromProxyLogMessage: message),
              requestBytes >= Self.proxyRequestHighWaterThresholdBytes else {
            return
        }
        perform(synchronously: false) {
            // AI request bodies grow a few KB per conversation turn, so a plain
            // strictly-greater gate fires on nearly every turn. Require a material
            // step over the prior high-water so the breadcrumb flags genuine jumps,
            // not the normal upward slope. This is diagnostic context (correlated
            // against memory-pressure incidents), not a warning condition.
            let step = Self.highWaterStepBytes(current: self.proxyRequestHighWaterBytes)
            guard requestBytes > self.proxyRequestHighWaterBytes + step else { return }
            self.proxyRequestHighWaterBytes = requestBytes
            let breadcrumb = IncidentBreadcrumb(
                id: self.makeID(),
                timestamp: self.now(),
                kind: .proxyRequestHighWater,
                severity: .info,
                message: "Large AI proxy request observed",
                metadata: [
                    "requestBytes": "\(requestBytes)",
                    "requestMB": String(format: "%.2f", Double(requestBytes) / 1_048_576.0)
                ]
            )
            self.append(breadcrumb)
        }
    }

    func reportPreviousCriticalMemoryPressureIfNeeded(maxAge: TimeInterval = 24 * 60 * 60) {
        perform(synchronously: false) {
            guard let breadcrumb = self.latestBreadcrumb(where: {
                $0.kind == .memoryPressure && $0.severity == .critical
            }) else {
                return
            }
            guard self.now().timeIntervalSince(breadcrumb.timestamp) <= maxAge else { return }

            let incidentID = breadcrumb.id.uuidString
            guard self.defaults.string(forKey: Self.reportedMemoryPressureIncidentKey) != incidentID else {
                return
            }
            self.defaults.set(incidentID, forKey: Self.reportedMemoryPressureIncidentKey)

            let summary = self.summary(for: breadcrumb)
            DispatchQueue.main.async {
                Log.warn("Previous memory-pressure incident detected: \(summary)")
            }
            let recovery = IncidentBreadcrumb(
                id: self.makeID(),
                timestamp: self.now(),
                kind: .appRecovery,
                severity: .info,
                message: "Previous critical memory-pressure incident surfaced at launch",
                metadata: [
                    "incidentID": incidentID,
                    "summary": summary
                ]
            )
            self.append(recovery)
        }
    }

    func recentBreadcrumbs(limit: Int = 100) -> [IncidentBreadcrumb] {
        var result: [IncidentBreadcrumb] = []
        perform(synchronously: true) {
            result = Array(self.readBreadcrumbs().suffix(limit))
        }
        return result
    }

    static func requestLength(fromProxyLogMessage message: String) -> Int? {
        guard let range = message.range(of: "reqLen=") else { return nil }
        let suffix = message[range.upperBound...]
        let digits = suffix.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }

    /// Minimum jump over the prior high-water mark before a new proxy-request
    /// breadcrumb is worth recording. Scales with the current mark (¼) but never
    /// drops below half the floor, so growth stays loggable without firing on the
    /// few-KB-per-turn slope of an accumulating conversation.
    static func highWaterStepBytes(current: Int) -> Int {
        max(proxyRequestHighWaterThresholdBytes / 2, current / 4)
    }

    private func perform(synchronously: Bool, _ work: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            work()
        } else if synchronously {
            queue.sync(execute: work)
        } else {
            queue.async(execute: work)
        }
    }

    private var directoryURL: URL {
        directoryProvider()
    }

    private var breadcrumbsURL: URL {
        directoryURL.appendingPathComponent("breadcrumbs.jsonl")
    }

    private var latestURL: URL {
        directoryURL.appendingPathComponent("latest.json")
    }

    private func append(_ breadcrumb: IncidentBreadcrumb) {
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try Self.encoder.encode(breadcrumb)
            var line = data
            line.append(0x0A)

            if !fileManager.fileExists(atPath: breadcrumbsURL.path) {
                fileManager.createFile(atPath: breadcrumbsURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: breadcrumbsURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try data.write(to: latestURL, options: .atomic)
            pruneIfNeeded()
        } catch {
            Log.warn("IncidentBreadcrumbStore: failed to write breadcrumb kind=\(breadcrumb.kind.rawValue) error=\(error)")
        }
    }

    private func readBreadcrumbs() -> [IncidentBreadcrumb] {
        guard let data = try? Data(contentsOf: breadcrumbsURL),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            try? Self.decoder.decode(IncidentBreadcrumb.self, from: Data(line.utf8))
        }
    }

    private func latestBreadcrumb(where predicate: (IncidentBreadcrumb) -> Bool) -> IncidentBreadcrumb? {
        readBreadcrumbs().reversed().first(where: predicate)
    }

    private func pruneIfNeeded() {
        guard let attributes = try? fileManager.attributesOfItem(atPath: breadcrumbsURL.path),
              let size = attributes[.size] as? UInt64,
              size > UInt64(Self.maxLogBytes) else {
            return
        }
        let retained = readBreadcrumbs().suffix(200)
        let lines = retained.compactMap { breadcrumb -> Data? in
            guard let encoded = try? Self.encoder.encode(breadcrumb) else { return nil }
            var line = encoded
            line.append(0x0A)
            return line
        }
        let data = lines.reduce(into: Data()) { $0.append($1) }
        try? data.write(to: breadcrumbsURL, options: .atomic)
    }

    private func summary(for breadcrumb: IncidentBreadcrumb) -> String {
        let resident = breadcrumb.metadata["residentMB"].map { "rss=\($0)MB" }
        let restoreBytes = breadcrumb.metadata["restore.totalUserDefaultsBytes"].flatMap(Int.init).map {
            "restoreDefaults=\($0 / 1024)KB"
        }
        let proxyBytes = breadcrumb.metadata["proxyRequestHighWaterBytes"].flatMap(Int.init).map {
            "proxyHighWater=\($0 / 1024)KB"
        }
        return ([breadcrumb.timestamp.ISO8601Format(), resident, restoreBytes, proxyBytes].compactMap { $0 })
            .joined(separator: " ")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private extension [String: String] {
    func mapKeys(_ transform: (String) -> String) -> [String: String] {
        [String: String](uniqueKeysWithValues: map { (transform($0.key), $0.value) })
    }
}
