import AppKit
import Chau7Core
import Foundation

/// Minimal network boundary for provider-status polling.
///
/// Keeping transport behind a protocol makes the monitor deterministic in
/// tests and prevents URLSession concerns from leaking into status policy.
protocol ProviderStatusDataFetching: Sendable {
    func data(from url: URL) async throws -> Data
}

struct URLSessionProviderStatusFetcher: ProviderStatusDataFetching {
    private let session: URLSession

    init(session: URLSession = URLSessionProviderStatusFetcher.makeSession()) {
        self.session = session
    }

    func data(from url: URL) async throws -> Data {
        let attribution = NetworkRequestAttribution(component: "provider_status", url: url)
        let requestID = String(UUID().uuidString.prefix(8))
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadRevalidatingCacheData
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        Log.trace("Network request started request_id=\(requestID) \(attribution.logFields)")
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  (200 ..< 300).contains(response.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw ProviderStatusTransportError.invalidResponse(status: status)
            }
            Log.trace(
                "Network request completed request_id=\(requestID) \(attribution.logFields) status=\(response.statusCode)"
            )
            return data
        } catch {
            Log.warn(
                "Network request failed request_id=\(requestID) \(attribution.logFields) error=\(String(describing: error))"
            )
            throw error
        }
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 15
        configuration.requestCachePolicy = .reloadRevalidatingCacheData
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Chau7 Provider Health Monitor"
        ]
        return URLSession(configuration: configuration)
    }
}

enum ProviderStatusTransportError: Error {
    case invalidResponse(status: Int)
}

/// One official provider-status source and the adapter needed to decode it.
private struct ProviderStatusSource: Sendable {
    enum Feed: Sendable {
        case statusPage(componentNameFragments: [String])
        case googleCloudIncidents
    }

    let providerKey: String
    let url: URL
    let feed: Feed

    func decode(_ data: Data, checkedAt: Date) throws -> ProviderHealthSnapshot {
        switch feed {
        case .statusPage(let componentNameFragments):
            return try StatusPageProviderHealthDecoder.decode(
                data,
                providerKey: providerKey,
                relevantComponentNameFragments: componentNameFragments,
                sourceURL: url,
                checkedAt: checkedAt
            )
        case .googleCloudIncidents:
            return try GoogleCloudProviderHealthDecoder.decode(
                data,
                providerKey: providerKey,
                sourceURL: url,
                checkedAt: checkedAt
            )
        }
    }
}

private enum ProviderStatusFetchOutcome: Sendable {
    case success(ProviderStatusSource, Data)
    case failure(ProviderStatusSource, String)
}

/// Polls official provider status feeds once for the whole application.
///
/// The monitor owns transport and freshness only. Vendor payload policy stays
/// in Chau7Core decoders, while views consume normalized snapshots.
@MainActor
@Observable
final class ProviderStatusMonitor {
    static let shared = ProviderStatusMonitor()

    /// Recent observations survive transient missed polls, but expire promptly.
    static let maximumSnapshotAge: TimeInterval = 5 * 60

    private(set) var snapshotsByProvider: [String: ProviderHealthSnapshot] = [:]

    @ObservationIgnored private let fetcher: any ProviderStatusDataFetching
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var foregroundObserver: NSObjectProtocol?
    @ObservationIgnored private var isRefreshInFlight = false
    @ObservationIgnored private(set) var consecutiveFailedRefreshes = 0
    @ObservationIgnored private(set) var nextRefreshAllowedAt: Date?

    private static let sources: [ProviderStatusSource] = [
        ProviderStatusSource(
            providerKey: "anthropic",
            url: providerStatusURL("https://status.claude.com/api/v2/summary.json"),
            feed: .statusPage(componentNameFragments: [
                "Claude API",
                "Claude Code"
            ])
        ),
        ProviderStatusSource(
            providerKey: "openai",
            url: providerStatusURL("https://status.openai.com/api/v2/summary.json"),
            feed: .statusPage(componentNameFragments: [
                "Responses",
                "Codex API",
                "VS Code extension",
                "Codex in ChatGPT Desktop"
            ])
        ),
        ProviderStatusSource(
            providerKey: "github",
            url: providerStatusURL("https://www.githubstatus.com/api/v2/summary.json"),
            feed: .statusPage(componentNameFragments: [
                "Copilot",
                "Copilot AI Model Providers"
            ])
        ),
        ProviderStatusSource(
            providerKey: "google",
            url: providerStatusURL("https://status.cloud.google.com/incidents.json"),
            feed: .googleCloudIncidents
        )
    ]

    private static func providerStatusURL(_ rawValue: String) -> URL {
        guard let url = URL(string: rawValue) else {
            preconditionFailure("Invalid provider status URL: \(rawValue)")
        }
        return url
    }

    init(fetcher: any ProviderStatusDataFetching = URLSessionProviderStatusFetcher()) {
        self.fetcher = fetcher
    }

    func start() {
        guard pollingTask == nil else { return }

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }

        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let nextPollSeconds = Double.random(in: 55 ... 70)
                try? await Task.sleep(for: .seconds(nextPollSeconds))
            }
        }
        Log.info("Provider status monitor started")
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
            self.foregroundObserver = nil
        }
    }

    func refresh(at now: Date = Date()) async {
        guard !isRefreshInFlight else { return }
        if let nextRefreshAllowedAt, now < nextRefreshAllowedAt { return }
        isRefreshInFlight = true
        defer { isRefreshInFlight = false }

        let fetcher = fetcher
        let outcomes = await withTaskGroup(
            of: ProviderStatusFetchOutcome.self,
            returning: [ProviderStatusFetchOutcome].self
        ) { group in
            for source in Self.sources {
                group.addTask {
                    do {
                        return try await .success(source, fetcher.data(from: source.url))
                    } catch {
                        return .failure(source, String(describing: error))
                    }
                }
            }

            var values: [ProviderStatusFetchOutcome] = []
            for await value in group {
                values.append(value)
            }
            return values
        }

        let checkedAt = now
        var updatedSnapshots = snapshotsByProvider
        var failures: [(provider: String, message: String)] = []
        for outcome in outcomes {
            switch outcome {
            case .success(let source, let data):
                do {
                    updatedSnapshots[source.providerKey] = try source.decode(
                        data,
                        checkedAt: checkedAt
                    )
                } catch {
                    Log.warn(
                        "Provider status decode failed provider=\(source.providerKey): \(error)"
                    )
                }
            case .failure(let source, let message):
                failures.append((source.providerKey, message))
            }
        }

        if failures.count == Self.sources.count {
            consecutiveFailedRefreshes += 1
            let delay = Self.retryDelay(afterConsecutiveFailures: consecutiveFailedRefreshes)
            nextRefreshAllowedAt = checkedAt.addingTimeInterval(delay)
            let providers = failures.map(\.provider).sorted().joined(separator: ",")
            let classes = Set(failures.map { Self.failureClass(for: $0.message) }).sorted().joined(separator: ",")
            Log.warn(
                "Provider status refresh unavailable providers=\(providers) " +
                    "error_classes=\(classes) retry_in=\(Int(delay))s"
            )
        } else {
            consecutiveFailedRefreshes = 0
            nextRefreshAllowedAt = nil
            if !failures.isEmpty {
                let providers = failures.map(\.provider).sorted().joined(separator: ",")
                Log.warn("Provider status partial refresh failure providers=\(providers)")
            }
        }

        // Preserve recent observations across transient network failures, then
        // remove them once they can no longer truthfully describe current state.
        updatedSnapshots = updatedSnapshots.filter {
            checkedAt.timeIntervalSince($0.value.checkedAt) <= Self.maximumSnapshotAge
        }
        snapshotsByProvider = updatedSnapshots
    }

    static func retryDelay(afterConsecutiveFailures failures: Int) -> TimeInterval {
        let exponent = min(max(0, failures - 1), 4)
        return min(15 * 60, 60 * pow(2, Double(exponent)))
    }

    static func failureClass(for message: String) -> String {
        let normalized = message.lowercased()
        if normalized.contains("offline") || normalized.contains("-1009") { return "offline" }
        if normalized.contains("timed out") || normalized.contains("-1001") { return "timeout" }
        if normalized.contains("hostname") || normalized.contains("-1003") { return "dns" }
        if normalized.contains("connection was lost") || normalized.contains("-1005") { return "connection_lost" }
        return "transport"
    }

    /// Returns a fresh alert for a detected AI tool/provider, or nil when the
    /// provider is healthy, unsupported, unknown, or stale.
    func activeSnapshot(
        for rawProvider: String?,
        at now: Date = Date()
    ) -> ProviderHealthSnapshot? {
        guard let providerKey = AnalyticsProvider.key(for: rawProvider),
              let snapshot = snapshotsByProvider[providerKey],
              snapshot.activeAlert(
                  at: now,
                  maximumAge: Self.maximumSnapshotAge
              ) != nil else {
            return nil
        }
        return snapshot
    }
}
