import Foundation

public enum UsageEvidenceSourceKind: String, Codable, CaseIterable, Sendable {
    case proxy
    case transcript
    case nativeStore
    case baseline
}

public struct UsageEvidence: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let uniqueEventKey: String
    public let reconciliationKey: String
    public let sourceKind: UsageEvidenceSourceKind
    public let provider: String
    public let model: String?
    public let sessionID: String?
    public let runID: String?
    public let endpoint: String?
    public let projectPath: String?
    public let inputTokens: Int?
    public let cacheCreationInputTokens: Int?
    public let cacheReadInputTokens: Int?
    public let outputTokens: Int?
    public let reasoningOutputTokens: Int?
    public let costUSD: Double?
    public let tokenUsageSource: TokenUsageSource?
    public let tokenUsageState: TelemetryMetricState
    public let costSource: CostSource?
    public let costState: TelemetryMetricState
    public let pricingVersion: String?
    public let sourceRef: String?
    public let observedAt: Date
    public let metadata: [String: String]

    public init(
        id: String,
        uniqueEventKey: String,
        reconciliationKey: String,
        sourceKind: UsageEvidenceSourceKind,
        provider: String,
        model: String? = nil,
        sessionID: String? = nil,
        runID: String? = nil,
        endpoint: String? = nil,
        projectPath: String? = nil,
        inputTokens: Int? = nil,
        cacheCreationInputTokens: Int? = nil,
        cacheReadInputTokens: Int? = nil,
        outputTokens: Int? = nil,
        reasoningOutputTokens: Int? = nil,
        costUSD: Double? = nil,
        tokenUsageSource: TokenUsageSource? = nil,
        tokenUsageState: TelemetryMetricState = .missing,
        costSource: CostSource? = nil,
        costState: TelemetryMetricState = .missing,
        pricingVersion: String? = nil,
        sourceRef: String? = nil,
        observedAt: Date,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.uniqueEventKey = uniqueEventKey
        self.reconciliationKey = reconciliationKey
        self.sourceKind = sourceKind
        self.provider = provider
        self.model = model
        self.sessionID = sessionID
        self.runID = runID
        self.endpoint = endpoint
        self.projectPath = projectPath
        self.inputTokens = inputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.costUSD = costUSD
        self.tokenUsageSource = tokenUsageSource
        self.tokenUsageState = tokenUsageState
        self.costSource = costSource
        self.costState = costState
        self.pricingVersion = pricingVersion
        self.sourceRef = sourceRef
        self.observedAt = observedAt
        self.metadata = metadata
    }

    public var tokenUsage: TokenUsage {
        TokenUsage(
            inputTokens: inputTokens ?? 0,
            cacheCreationInputTokens: cacheCreationInputTokens ?? 0,
            cacheReadInputTokens: cacheReadInputTokens ?? 0,
            cachedInputTokens: (cacheCreationInputTokens ?? 0) + (cacheReadInputTokens ?? 0),
            outputTokens: outputTokens ?? 0,
            reasoningOutputTokens: reasoningOutputTokens ?? 0
        )
    }

    public var hasAnyTokens: Bool {
        inputTokens != nil ||
            cacheCreationInputTokens != nil ||
            cacheReadInputTokens != nil ||
            outputTokens != nil ||
            reasoningOutputTokens != nil
    }

    // swiftlint:disable:next function_parameter_count
    public static func proxyEvent(
        provider: String,
        model: String?,
        sessionID: String?,
        endpoint: String?,
        projectPath: String?,
        observedAt: Date,
        inputTokens: Int?,
        outputTokens: Int?,
        cacheCreationInputTokens: Int?,
        cacheReadInputTokens: Int?,
        reasoningOutputTokens: Int?,
        costUSD: Double?,
        pricingVersion: String?,
        metadata: [String: String] = [:]
    ) -> UsageEvidence {
        let normalizedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedSessionID = normalizedNonEmpty(sessionID)
        let normalizedModel = normalizedNonEmpty(model)
        let normalizedEndpoint = normalizedNonEmpty(endpoint)
        let normalizedProjectPath = normalizedNonEmpty(projectPath)
        let timestamp = ISO8601DateFormatter().string(from: observedAt)
        let inputKey = inputTokens.map(String.init) ?? "nil"
        let outputKey = outputTokens.map(String.init) ?? "nil"
        let cacheCreationKey = cacheCreationInputTokens.map(String.init) ?? "nil"
        let cacheReadKey = cacheReadInputTokens.map(String.init) ?? "nil"
        let reasoningKey = reasoningOutputTokens.map(String.init) ?? "nil"
        let costKey = costUSD.map { String(format: "%.8f", $0) } ?? "nil"
        let keyParts: [String] = [
            "proxy",
            normalizedProvider,
            normalizedSessionID ?? "-",
            normalizedModel ?? "-",
            normalizedEndpoint ?? "-",
            timestamp,
            inputKey,
            outputKey,
            cacheCreationKey,
            cacheReadKey,
            reasoningKey,
            costKey
        ]
        let uniqueEventKey = keyParts.joined(separator: "|")
        return UsageEvidence(
            id: uniqueEventKey,
            uniqueEventKey: uniqueEventKey,
            reconciliationKey: defaultReconciliationKey(
                sourceKind: .proxy,
                provider: normalizedProvider,
                sessionID: normalizedSessionID,
                runID: nil,
                projectPath: normalizedProjectPath,
                observedAt: observedAt
            ),
            sourceKind: .proxy,
            provider: normalizedProvider,
            model: normalizedModel,
            sessionID: normalizedSessionID,
            runID: nil,
            endpoint: normalizedEndpoint,
            projectPath: normalizedProjectPath,
            inputTokens: inputTokens,
            cacheCreationInputTokens: cacheCreationInputTokens,
            cacheReadInputTokens: cacheReadInputTokens,
            outputTokens: outputTokens,
            reasoningOutputTokens: reasoningOutputTokens,
            costUSD: costUSD,
            tokenUsageSource: .proxy,
            tokenUsageState: tokenState(
                inputTokens: inputTokens,
                cacheCreationInputTokens: cacheCreationInputTokens,
                cacheReadInputTokens: cacheReadInputTokens,
                outputTokens: outputTokens,
                reasoningOutputTokens: reasoningOutputTokens
            ),
            costSource: costUSD == nil ? .unavailable : .observed,
            costState: costUSD == nil ? .missing : .complete,
            pricingVersion: normalizedNonEmpty(pricingVersion),
            sourceRef: normalizedEndpoint,
            observedAt: observedAt,
            metadata: metadata
        )
    }

    public static func runSummary(_ run: TelemetryRun) -> UsageEvidence {
        let cacheBreakdown = normalizedCacheBreakdown(
            cacheCreationInputTokens: run.totalCacheCreationInputTokens,
            cacheReadInputTokens: run.totalCacheReadInputTokens,
            cachedInputTokens: run.totalCachedInputTokens
        )
        let sourceKind: UsageEvidenceSourceKind
        switch run.tokenUsageSource {
        case .proxy:
            sourceKind = .proxy
        case .transcriptDelta, .transcriptSnapshot:
            sourceKind = .transcript
        case .providerEstimate:
            sourceKind = .nativeStore
        case .unknown, nil:
            sourceKind = .nativeStore
        }

        let uniqueEventKey = "run|\(run.id)"
        return UsageEvidence(
            id: uniqueEventKey,
            uniqueEventKey: uniqueEventKey,
            reconciliationKey: defaultReconciliationKey(
                sourceKind: sourceKind,
                provider: run.provider.lowercased(),
                sessionID: normalizedNonEmpty(run.sessionID),
                runID: run.id,
                projectPath: normalizedNonEmpty(run.repoPath ?? run.cwd),
                observedAt: run.endedAt ?? run.startedAt
            ),
            sourceKind: sourceKind,
            provider: run.provider.lowercased(),
            model: normalizedNonEmpty(run.model),
            sessionID: normalizedNonEmpty(run.sessionID),
            runID: run.id,
            endpoint: nil,
            projectPath: normalizedNonEmpty(run.repoPath ?? run.cwd),
            inputTokens: run.totalInputTokens,
            cacheCreationInputTokens: cacheBreakdown.creation,
            cacheReadInputTokens: cacheBreakdown.read,
            outputTokens: run.totalOutputTokens,
            reasoningOutputTokens: run.totalReasoningOutputTokens,
            costUSD: run.costUSD,
            tokenUsageSource: run.tokenUsageSource,
            tokenUsageState: run.tokenUsageState,
            costSource: run.costSource,
            costState: run.costState,
            pricingVersion: run.costSource == .estimated ? ModelPricingTable.version : nil,
            sourceRef: normalizedNonEmpty(run.rawTranscriptRef),
            observedAt: run.endedAt ?? run.startedAt,
            metadata: run.metadata
        )
    }

    private static func normalizedCacheBreakdown(
        cacheCreationInputTokens: Int?,
        cacheReadInputTokens: Int?,
        cachedInputTokens: Int?
    ) -> (creation: Int?, read: Int?) {
        let creation = cacheCreationInputTokens
        let read = cacheReadInputTokens
        let combined = cachedInputTokens

        guard let combined else {
            return (creation, read)
        }

        switch (creation, read) {
        case let (.some(creation), .some(read)):
            return (creation, read)
        case let (.some(creation), nil):
            let remaining = max(0, combined - creation)
            return (creation, remaining > 0 ? remaining : nil)
        case let (nil, .some(read)):
            let remaining = max(0, combined - read)
            return (remaining > 0 ? remaining : nil, read)
        case (nil, nil):
            return (nil, combined > 0 ? combined : nil)
        }
    }

    private static func tokenState(
        inputTokens: Int?,
        cacheCreationInputTokens: Int?,
        cacheReadInputTokens: Int?,
        outputTokens: Int?,
        reasoningOutputTokens: Int?
    ) -> TelemetryMetricState {
        if inputTokens == nil,
           cacheCreationInputTokens == nil,
           cacheReadInputTokens == nil,
           outputTokens == nil,
           reasoningOutputTokens == nil {
            return .missing
        }
        return .complete
    }

    private static func defaultReconciliationKey(
        sourceKind: UsageEvidenceSourceKind,
        provider: String,
        sessionID: String?,
        runID: String?,
        projectPath: String?,
        observedAt: Date
    ) -> String {
        if let sessionID {
            return "session|\(provider)|\(sessionID)"
        }
        if let runID {
            return "run|\(provider)|\(runID)"
        }
        if let projectPath {
            let day = ISO8601DateFormatter().string(from: observedAt).prefix(10)
            return "project|\(provider)|\(projectPath)|\(day)"
        }
        return "day|\(provider)|\(ISO8601DateFormatter().string(from: observedAt).prefix(10))"
    }

    private static func normalizedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

public struct UsageEvidenceAggregate: Codable, Equatable, Sendable {
    public let reconciliationKey: String
    public let sourceKind: UsageEvidenceSourceKind
    public let provider: String
    public let model: String?
    public let sessionID: String?
    public let runIDs: [String]
    public let inputTokens: Int?
    public let cacheCreationInputTokens: Int?
    public let cacheReadInputTokens: Int?
    public let outputTokens: Int?
    public let reasoningOutputTokens: Int?
    public let costUSD: Double?
    public let tokenUsageSource: TokenUsageSource?
    public let tokenUsageState: TelemetryMetricState
    public let costSource: CostSource?
    public let costState: TelemetryMetricState
    public let pricingVersions: [String]
    public let sourceRefs: [String]
    public let observedAt: Date
    public let evidenceIDs: [String]

    public var tokenUsage: TokenUsage {
        TokenUsage(
            inputTokens: inputTokens ?? 0,
            cacheCreationInputTokens: cacheCreationInputTokens ?? 0,
            cacheReadInputTokens: cacheReadInputTokens ?? 0,
            cachedInputTokens: (cacheCreationInputTokens ?? 0) + (cacheReadInputTokens ?? 0),
            outputTokens: outputTokens ?? 0,
            reasoningOutputTokens: reasoningOutputTokens ?? 0
        )
    }

    public var hasAnyTokens: Bool {
        inputTokens != nil ||
            cacheCreationInputTokens != nil ||
            cacheReadInputTokens != nil ||
            outputTokens != nil ||
            reasoningOutputTokens != nil
    }
}

public enum UsageReconciliationConfidence: String, Codable, CaseIterable, Sendable {
    case observed
    case mixed
    case estimated
    case incomplete
}

public struct ReconciledUsageGroup: Codable, Equatable, Sendable {
    public let reconciliationKey: String
    public let provider: String
    public let selected: UsageEvidenceAggregate
    public let alternatives: [UsageEvidenceAggregate]
    public let confidence: UsageReconciliationConfidence
    public let costDeltaUSD: Double?
    public let tokenDelta: Int?
}

public struct UsageReconciliationReport: Codable, Equatable, Sendable {
    public let groups: [ReconciledUsageGroup]
    public let totalCostUSD: Double
    public let totalTokenUsage: TokenUsage
}

public enum UsageReconciliationService {
    public static func reconcile(_ evidence: [UsageEvidence]) -> UsageReconciliationReport {
        let deduped = Dictionary(evidence.map { ($0.uniqueEventKey, $0) }, uniquingKeysWith: { current, _ in current }).values
        let grouped = Dictionary(grouping: deduped) { evidence in
            "\(evidence.provider)|\(evidence.reconciliationKey)"
        }

        var totalCostUSD = 0.0
        var totalTokenUsage = TokenUsage()
        let groups = grouped.keys.sorted().compactMap { key -> ReconciledUsageGroup? in
            guard let entries = grouped[key], !entries.isEmpty else { return nil }
            let aggregates = aggregate(entries)
            guard let selected = aggregates.max(by: { selectionScore($0) < selectionScore($1) }) else {
                return nil
            }
            let alternatives = aggregates
                .filter { $0 != selected }
                .sorted { selectionScore($0) > selectionScore($1) }
            totalCostUSD += selected.costUSD ?? 0
            totalTokenUsage.add(selected.tokenUsage)
            let topAlternative = alternatives.first
            return ReconciledUsageGroup(
                reconciliationKey: selected.reconciliationKey,
                provider: selected.provider,
                selected: selected,
                alternatives: alternatives,
                confidence: confidence(selected: selected, alternatives: alternatives),
                costDeltaUSD: delta(selected.costUSD, topAlternative?.costUSD),
                tokenDelta: delta(selected.tokenUsage.totalBillableTokens, topAlternative?.tokenUsage.totalBillableTokens)
            )
        }
        .sorted { $0.reconciliationKey < $1.reconciliationKey }

        return UsageReconciliationReport(
            groups: groups,
            totalCostUSD: totalCostUSD,
            totalTokenUsage: totalTokenUsage
        )
    }

    private static func aggregate(_ evidence: [UsageEvidence]) -> [UsageEvidenceAggregate] {
        Dictionary(grouping: evidence, by: \.sourceKind).values.compactMap { bucket in
            guard let first = bucket.first else { return nil }
            return UsageEvidenceAggregate(
                reconciliationKey: first.reconciliationKey,
                sourceKind: first.sourceKind,
                provider: first.provider,
                model: bucket.compactMap(\.model).last,
                sessionID: bucket.compactMap(\.sessionID).last,
                runIDs: Array(Set(bucket.compactMap(\.runID))).sorted(),
                inputTokens: sum(bucket.map(\.inputTokens)),
                cacheCreationInputTokens: sum(bucket.map(\.cacheCreationInputTokens)),
                cacheReadInputTokens: sum(bucket.map(\.cacheReadInputTokens)),
                outputTokens: sum(bucket.map(\.outputTokens)),
                reasoningOutputTokens: sum(bucket.map(\.reasoningOutputTokens)),
                costUSD: sum(bucket.map(\.costUSD)),
                tokenUsageSource: bucket.compactMap(\.tokenUsageSource).max(by: tokenUsageSourceScore),
                tokenUsageState: reduceState(bucket.map(\.tokenUsageState)),
                costSource: bucket.compactMap(\.costSource).max(by: costSourceScore),
                costState: reduceState(bucket.map(\.costState)),
                pricingVersions: Array(Set(bucket.compactMap(\.pricingVersion))).sorted(),
                sourceRefs: Array(Set(bucket.compactMap(\.sourceRef))).sorted(),
                observedAt: bucket.map(\.observedAt).max() ?? first.observedAt,
                evidenceIDs: bucket.map(\.id).sorted()
            )
        }
    }

    private static func selectionScore(_ aggregate: UsageEvidenceAggregate) -> Int {
        var score = 0
        switch aggregate.sourceKind {
        case .proxy:
            score += 400
        case .nativeStore:
            score += 320
        case .transcript:
            score += 280
        case .baseline:
            score += 180
        }
        switch aggregate.costSource {
        case .observed:
            score += 100
        case .estimated:
            score += 50
        case .unavailable, nil:
            break
        }
        switch aggregate.costState {
        case .complete:
            score += 60
        case .estimated:
            score += 30
        case .missing:
            break
        case .invalid:
            score -= 500
        }
        switch aggregate.tokenUsageState {
        case .complete:
            score += 60
        case .estimated:
            score += 30
        case .missing:
            break
        case .invalid:
            score -= 500
        }
        if aggregate.costUSD != nil {
            score += 20
        }
        if aggregate.hasAnyTokens {
            score += 20
        }
        if !aggregate.pricingVersions.isEmpty {
            score += 5
        }
        return score
    }

    private static func confidence(
        selected: UsageEvidenceAggregate,
        alternatives: [UsageEvidenceAggregate]
    ) -> UsageReconciliationConfidence {
        if selected.sourceKind == .proxy,
           selected.costSource == .observed,
           selected.costState == .complete,
           selected.tokenUsageState == .complete {
            return .observed
        }
        if selected.costSource == .estimated || selected.costState == .estimated || selected.tokenUsageState == .estimated {
            return .estimated
        }
        if !alternatives.isEmpty {
            return .mixed
        }
        return .incomplete
    }

    private static func reduceState(_ states: [TelemetryMetricState]) -> TelemetryMetricState {
        let unique = Set(states)
        if unique.contains(.invalid) {
            return .invalid
        }
        if unique == [.missing] {
            return .missing
        }
        if unique == [.complete] {
            return .complete
        }
        if unique.contains(.estimated) {
            return .estimated
        }
        if unique.contains(.complete) {
            return .complete
        }
        return .missing
    }

    private static func sum(_ values: [Int?]) -> Int? {
        let present = values.compactMap { $0 }
        guard !present.isEmpty else { return nil }
        return present.reduce(0, +)
    }

    private static func sum(_ values: [Double?]) -> Double? {
        let present = values.compactMap { $0 }
        guard !present.isEmpty else { return nil }
        return present.reduce(0, +)
    }

    private static func delta(_ lhs: Double?, _ rhs: Double?) -> Double? {
        guard let lhs, let rhs else { return nil }
        return lhs - rhs
    }

    private static func delta(_ lhs: Int, _ rhs: Int?) -> Int? {
        guard let rhs else { return nil }
        return lhs - rhs
    }

    private static func tokenUsageSourceScore(_ lhs: TokenUsageSource, _ rhs: TokenUsageSource) -> Bool {
        tokenUsageSourceWeight(lhs) < tokenUsageSourceWeight(rhs)
    }

    private static func tokenUsageSourceWeight(_ source: TokenUsageSource) -> Int {
        switch source {
        case .proxy:
            return 50
        case .transcriptSnapshot:
            return 40
        case .transcriptDelta:
            return 35
        case .providerEstimate:
            return 20
        case .unknown:
            return 10
        }
    }

    private static func costSourceScore(_ lhs: CostSource, _ rhs: CostSource) -> Bool {
        costSourceWeight(lhs) < costSourceWeight(rhs)
    }

    private static func costSourceWeight(_ source: CostSource) -> Int {
        switch source {
        case .observed:
            return 30
        case .estimated:
            return 20
        case .unavailable:
            return 10
        }
    }
}
