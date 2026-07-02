import Foundation

// MARK: - Identity

public enum MagiMemberID: String, Codable, CaseIterable, Identifiable, Sendable {
    case melchior
    case balthasar
    case casper

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .melchior: return "Melchior"
        case .balthasar: return "Balthasar"
        case .casper: return "Casper"
        }
    }
}

public enum MagiModelClass: String, Codable, CaseIterable, Identifiable, Sendable {
    case fast
    case balanced
    case strongest

    public var id: String { rawValue }
}

public enum MagiReasoningLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case low
    case medium
    case high
    case max

    public var id: String { rawValue }
}

public enum MagiProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex
    case claude
    case gemini

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        }
    }
}

public enum MagiFallbackStrategy: String, Codable, CaseIterable, Identifiable, Sendable {
    case duplicate
    case fail

    public var id: String { rawValue }
}

// MARK: - Configuration

public struct MagiMemberConfiguration: Codable, Equatable, Sendable {
    public var provider: String
    public var modelClass: MagiModelClass
    public var reasoning: MagiReasoningLevel
    public var modelName: String?

    public init(
        provider: String,
        modelClass: MagiModelClass = .balanced,
        reasoning: MagiReasoningLevel = .max,
        modelName: String? = nil
    ) {
        self.provider = provider
        self.modelClass = modelClass
        self.reasoning = reasoning
        self.modelName = modelName
    }
}

public struct MagiConfig: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var defaultCouncilID: String
    public var defaultReasoning: MagiReasoningLevel
    public var fallbackStrategy: MagiFallbackStrategy
    public var webAccessAllowed: Bool
    public var evidenceRequiresApproval: Bool
    public var deadlockExtraRoundEnabled: Bool
    public var vetoBlocksVerdict: Bool
    public var members: [MagiMemberID: MagiMemberConfiguration]

    public init(
        schemaVersion: Int = MagiConfig.currentSchemaVersion,
        defaultCouncilID: String = "magi",
        defaultReasoning: MagiReasoningLevel = .max,
        fallbackStrategy: MagiFallbackStrategy = .duplicate,
        webAccessAllowed: Bool = true,
        evidenceRequiresApproval: Bool = true,
        deadlockExtraRoundEnabled: Bool = true,
        vetoBlocksVerdict: Bool = true,
        members: [MagiMemberID: MagiMemberConfiguration] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.defaultCouncilID = defaultCouncilID
        self.defaultReasoning = defaultReasoning
        self.fallbackStrategy = fallbackStrategy
        self.webAccessAllowed = webAccessAllowed
        self.evidenceRequiresApproval = evidenceRequiresApproval
        self.deadlockExtraRoundEnabled = deadlockExtraRoundEnabled
        self.vetoBlocksVerdict = vetoBlocksVerdict
        self.members = members
    }
}

// MARK: - Council

public struct MagiPersona: Codable, Equatable, Sendable {
    public var memberID: MagiMemberID
    public var displayName: String
    public var lens: String
    public var prompt: String
    public var vetoPolicy: String?
    public var isUserEditable: Bool

    public init(
        memberID: MagiMemberID,
        displayName: String? = nil,
        lens: String,
        prompt: String,
        vetoPolicy: String? = nil,
        isUserEditable: Bool = true
    ) {
        self.memberID = memberID
        self.displayName = displayName ?? memberID.displayName
        self.lens = lens
        self.prompt = prompt
        self.vetoPolicy = vetoPolicy
        self.isUserEditable = isUserEditable
    }
}

public struct MagiMember: Codable, Equatable, Sendable, Identifiable {
    public var id: MagiMemberID
    public var persona: MagiPersona
    public var provider: String
    public var modelClass: MagiModelClass
    public var reasoning: MagiReasoningLevel
    public var weight: Double

    public init(
        id: MagiMemberID,
        persona: MagiPersona,
        provider: String,
        modelClass: MagiModelClass = .balanced,
        reasoning: MagiReasoningLevel = .max,
        weight: Double = 1.0
    ) {
        self.id = id
        self.persona = persona
        self.provider = provider
        self.modelClass = modelClass
        self.reasoning = reasoning
        self.weight = max(0, weight)
    }
}

public struct MagiCouncil: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var members: [MagiMember]
    public var majorityThreshold: Int

    public init(
        id: String = "magi",
        name: String = "MAGI",
        members: [MagiMember],
        majorityThreshold: Int = 2
    ) {
        self.id = id
        self.name = name
        self.members = members
        self.majorityThreshold = majorityThreshold
    }

    public var hasDefaultMemberSet: Bool {
        Set(members.map(\.id)) == Set(MagiMemberID.allCases)
    }

    public static func defaultMagi(members: [MagiMemberID: MagiMemberConfiguration]) -> MagiCouncil {
        let defaultPersonas = MagiPersona.defaultPersonasByID
        let resolvedMembers = MagiMemberID.allCases.map { memberID in
            let config = members[memberID] ?? MagiMemberConfiguration(provider: "unconfigured")
            let persona = defaultPersonas[memberID] ?? MagiPersona(
                memberID: memberID,
                lens: "General MAGI council judgment.",
                prompt: "Evaluate the question through this member's configured judgment lens."
            )
            return MagiMember(
                id: memberID,
                persona: persona,
                provider: config.provider,
                modelClass: config.modelClass,
                reasoning: config.reasoning,
                weight: 1.0
            )
        }
        return MagiCouncil(members: resolvedMembers)
    }
}

public extension MagiPersona {
    static let defaultPersonasByID: [MagiMemberID: MagiPersona] = [
        .melchior: MagiPersona(
            memberID: .melchior,
            lens: "Rational, scientific, and systemic judgment.",
            prompt: "Evaluate the question through facts, consistency, architecture, feasibility, and technical truth."
        ),
        .balthasar: MagiPersona(
            memberID: .balthasar,
            lens: "Protective, continuity, and risk judgment.",
            prompt: "Evaluate the question through safety, survival, reversibility, operational risk, and long-term continuity."
        ),
        .casper: MagiPersona(
            memberID: .casper,
            lens: "Human, intuitive, and social judgment.",
            prompt: "Evaluate the question through human meaning, taste, motivation, emotional impact, and social consequence."
        )
    ]
}

// MARK: - Rounds

public enum MagiRoundSharePolicy: String, Codable, Sendable {
    case isolated
    case completedOutputsOnly
    case approvedEvidenceOnly
}

public enum MagiRoundKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case independentAnalysis
    case crossExamination
    case evidenceCollection
    case revision
    case vote
    case extraDeliberation

    public var id: String { rawValue }

    public var sharePolicy: MagiRoundSharePolicy {
        switch self {
        case .independentAnalysis:
            return .isolated
        case .evidenceCollection:
            return .approvedEvidenceOnly
        case .crossExamination, .revision, .vote, .extraDeliberation:
            return .completedOutputsOnly
        }
    }
}

public struct MagiRound: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var index: Int
    public var kind: MagiRoundKind
    public var startedAt: Date
    public var completedAt: Date?

    public init(
        id: String,
        index: Int,
        kind: MagiRoundKind,
        startedAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.index = index
        self.kind = kind
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

// MARK: - Deliberation Objects

public enum MagiEvidencePriority: String, Codable, CaseIterable, Sendable {
    case low
    case medium
    case high
    case blocking
}

public enum MagiEvidenceRequestStatus: String, Codable, CaseIterable, Sendable {
    case pendingApproval
    case approved
    case denied
    case fulfilled
}

public struct MagiEvidenceRequest: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var memberID: MagiMemberID
    public var roundID: String
    public var priority: MagiEvidencePriority
    public var reason: String
    public var requiredEvidence: [String]
    public var proposedCollectors: [String]
    public var status: MagiEvidenceRequestStatus

    public init(
        id: String,
        memberID: MagiMemberID,
        roundID: String,
        priority: MagiEvidencePriority,
        reason: String,
        requiredEvidence: [String],
        proposedCollectors: [String] = [],
        status: MagiEvidenceRequestStatus = .pendingApproval
    ) {
        self.id = id
        self.memberID = memberID
        self.roundID = roundID
        self.priority = priority
        self.reason = reason
        self.requiredEvidence = requiredEvidence
        self.proposedCollectors = proposedCollectors
        self.status = status
    }
}

public struct MagiEvidencePacket: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var requestID: String?
    public var collectorID: String
    public var summary: String
    public var content: String
    public var sourceDescription: String
    public var capturedAt: Date
    public var metadata: [String: String]

    public init(
        id: String,
        requestID: String? = nil,
        collectorID: String,
        summary: String,
        content: String,
        sourceDescription: String,
        capturedAt: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.requestID = requestID
        self.collectorID = collectorID
        self.summary = summary
        self.content = content
        self.sourceDescription = sourceDescription
        self.capturedAt = capturedAt
        self.metadata = metadata
    }
}

public enum MagiEvidenceCollectorKind: String, Codable, Sendable {
    case localGitStatus = "local.git_status"
    case localGitDiff = "local.git_diff"
    case localRepoSearch = "local.repo_search"
    case localFileRead = "local.file_read"
    case localCommand = "local.command"
    case webQuery = "web.query"
    case unsupported

    public static let v1: [MagiEvidenceCollectorKind] = [
        .localGitStatus,
        .localGitDiff,
        .localRepoSearch,
        .localFileRead,
        .localCommand,
        .webQuery
    ]
}

public struct MagiVeto: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var memberID: MagiMemberID
    public var reason: String
    public var scope: String
    public var blocksVerdict: Bool

    public init(
        id: String,
        memberID: MagiMemberID,
        reason: String,
        scope: String = "run",
        blocksVerdict: Bool = true
    ) {
        self.id = id
        self.memberID = memberID
        self.reason = reason
        self.scope = scope
        self.blocksVerdict = blocksVerdict
    }
}

public struct MagiPosition: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var memberID: MagiMemberID
    public var roundID: String
    public var recommendation: String
    public var summary: String
    public var confidence: Double
    public var evidenceRequests: [MagiEvidenceRequest]
    public var veto: MagiVeto?
    public var rawOutput: String?

    public init(
        id: String,
        memberID: MagiMemberID,
        roundID: String,
        recommendation: String,
        summary: String,
        confidence: Double,
        evidenceRequests: [MagiEvidenceRequest] = [],
        veto: MagiVeto? = nil,
        rawOutput: String? = nil
    ) {
        self.id = id
        self.memberID = memberID
        self.roundID = roundID
        self.recommendation = recommendation
        self.summary = summary
        self.confidence = min(1, max(0, confidence))
        self.evidenceRequests = evidenceRequests
        self.veto = veto
        self.rawOutput = rawOutput
    }
}

public struct MagiCritique: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var criticMemberID: MagiMemberID
    public var targetMemberID: MagiMemberID
    public var roundID: String
    public var agreements: [String]
    public var disagreements: [String]
    public var missingEvidence: [String]
    public var rawOutput: String?

    public init(
        id: String,
        criticMemberID: MagiMemberID,
        targetMemberID: MagiMemberID,
        roundID: String,
        agreements: [String] = [],
        disagreements: [String] = [],
        missingEvidence: [String] = [],
        rawOutput: String? = nil
    ) {
        self.id = id
        self.criticMemberID = criticMemberID
        self.targetMemberID = targetMemberID
        self.roundID = roundID
        self.agreements = agreements
        self.disagreements = disagreements
        self.missingEvidence = missingEvidence
        self.rawOutput = rawOutput
    }
}

// MARK: - Verdicts

public struct MagiVote: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var memberID: MagiMemberID
    public var verdictKind: MagiVerdictKind?
    public var choice: String
    public var confidence: Double
    public var rationale: String
    public var rawOutput: String?

    public init(
        id: String,
        memberID: MagiMemberID,
        verdictKind: MagiVerdictKind? = nil,
        choice: String,
        confidence: Double,
        rationale: String,
        rawOutput: String? = nil
    ) {
        self.id = id
        self.memberID = memberID
        self.verdictKind = verdictKind
        self.choice = choice
        self.confidence = min(1, max(0, confidence))
        self.rationale = rationale
        self.rawOutput = rawOutput
    }

    public var normalizedChoice: String {
        choice.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

public enum MagiVerdictKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case approve = "APPROVE"
    case reject = "REJECT"
    case conditional = "CONDITIONAL"
    case needEvidence = "NEED_EVIDENCE"
    case deadlock = "DEADLOCK"
    case escalate = "ESCALATE"
    case blockedByVeto = "BLOCKED_BY_VETO"
    case select = "SELECT"
    case rank = "RANK"
    case noConsensus = "NO_CONSENSUS"

    public var id: String { rawValue }

    public var isApprovalStyle: Bool {
        switch self {
        case .approve, .reject, .conditional, .needEvidence, .escalate:
            return true
        case .deadlock, .blockedByVeto, .select, .rank, .noConsensus:
            return false
        }
    }

    public var isSelectionStyle: Bool {
        switch self {
        case .select, .rank:
            return true
        case .approve, .reject, .conditional, .needEvidence, .deadlock, .escalate, .blockedByVeto, .noConsensus:
            return false
        }
    }

    public static func parse(_ value: String?) -> MagiVerdictKind? {
        guard let value else { return nil }
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .uppercased()
        return MagiVerdictKind.allCases.first { $0.rawValue == normalized }
    }

    public static func inferApprovalStyle(from choice: String) -> MagiVerdictKind? {
        if let parsed = parse(choice), parsed.isApprovalStyle {
            return parsed
        }

        let normalized = choice
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        if normalized.contains("need evidence")
            || normalized.contains("needs evidence")
            || normalized.contains("more evidence")
            || normalized.contains("insufficient evidence")
            || normalized.contains("not enough evidence") {
            return .needEvidence
        }

        if normalized.contains("escalate") {
            return .escalate
        }

        if normalized.contains("reject")
            || normalized.contains("do not approve")
            || normalized.contains("don't approve")
            || normalized.contains("do not merge")
            || normalized.contains("don't merge")
            || normalized.contains("do not ship")
            || normalized.contains("don't ship")
            || normalized.contains("block")
            || normalized.contains("not ready")
            || normalized == "no" {
            return .reject
        }

        if normalized.contains("conditional")
            || normalized.contains("approve if")
            || normalized.contains("approve only if")
            || normalized.contains("only if")
            || normalized.contains("provided that")
            || normalized.contains("with conditions") {
            return .conditional
        }

        if normalized.contains("approve")
            || normalized.contains("merge")
            || normalized.contains("ship")
            || normalized.contains("deploy")
            || normalized.contains("release")
            || normalized.contains("proceed")
            || normalized == "yes" {
            return .approve
        }

        return nil
    }
}

public enum MagiQuestionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case engineering
    case generic

    public var id: String { rawValue }

    public var voteVerdictKinds: [MagiVerdictKind] {
        switch self {
        case .engineering:
            return [.approve, .reject, .conditional, .needEvidence, .escalate]
        case .generic:
            return [.select, .rank]
        }
    }

    public var promptInstruction: String {
        switch self {
        case .engineering:
            return "Use approve/reject-style verdicts: APPROVE, REJECT, CONDITIONAL, NEED_EVIDENCE, or ESCALATE."
        case .generic:
            return "Use generic verdicts: SELECT for one answer or RANK for an ordered answer."
        }
    }

    public static func infer(from question: String) -> MagiQuestionKind {
        let normalized = question
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")

        let hardEngineeringDecisionSignals = [
            "merge",
            "pull request",
            " pr ",
            "deploy",
            "release",
            "ship",
            "rollback",
            "production",
            "security"
        ]
        if hardEngineeringDecisionSignals.contains(where: { normalized.contains($0) }) {
            return .engineering
        }

        let engineeringSignals = [
            "diff",
            "test",
            "build",
            "compile",
            "bug",
            "fix",
            "refactor",
            "migration",
            "schema",
            "api",
            "cli",
            "mcp",
            "commit",
            "repository",
            "repo"
        ]
        let approvalSignals = [
            "should",
            "can we",
            "can i",
            "do we",
            "is this",
            "is it",
            "approve",
            "reject",
            "block",
            "allow",
            "ready"
        ]

        if engineeringSignals.contains(where: { normalized.contains($0) })
            && approvalSignals.contains(where: { normalized.contains($0) }) {
            return .engineering
        }

        return .generic
    }
}

public struct MagiVerdict: Codable, Equatable, Sendable {
    public var kind: MagiVerdictKind
    public var decision: String?
    public var consensusScore: Double
    public var confidence: Double
    public var votes: [MagiVote]
    public var vetoes: [MagiVeto]
    public var requiresAdditionalRound: Bool
    public var rationale: String

    public init(
        kind: MagiVerdictKind,
        decision: String? = nil,
        consensusScore: Double = 0,
        confidence: Double = 0,
        votes: [MagiVote] = [],
        vetoes: [MagiVeto] = [],
        requiresAdditionalRound: Bool = false,
        rationale: String = ""
    ) {
        self.kind = kind
        self.decision = decision
        self.consensusScore = min(1, max(0, consensusScore))
        self.confidence = min(1, max(0, confidence))
        self.votes = votes
        self.vetoes = vetoes
        self.requiresAdditionalRound = requiresAdditionalRound
        self.rationale = rationale
    }
}

public struct MagiResolutionPolicy: Codable, Equatable, Sendable {
    public var majorityThreshold: Int
    public var deadlockExtraRoundEnabled: Bool
    public var vetoBlocksVerdict: Bool

    public init(
        majorityThreshold: Int = 2,
        deadlockExtraRoundEnabled: Bool = true,
        vetoBlocksVerdict: Bool = true
    ) {
        self.majorityThreshold = max(1, majorityThreshold)
        self.deadlockExtraRoundEnabled = deadlockExtraRoundEnabled
        self.vetoBlocksVerdict = vetoBlocksVerdict
    }
}

public enum MagiDecisionResolver {
    public static func resolve(
        votes: [MagiVote],
        vetoes: [MagiVeto] = [],
        policy: MagiResolutionPolicy = MagiResolutionPolicy(),
        questionKind: MagiQuestionKind = .generic
    ) -> MagiVerdict {
        let blockingVetoes = vetoes.filter(\.blocksVerdict)
        if policy.vetoBlocksVerdict, !blockingVetoes.isEmpty {
            return MagiVerdict(
                kind: .blockedByVeto,
                consensusScore: 0,
                confidence: blockingVetoes.isEmpty ? 0 : 1,
                votes: votes,
                vetoes: blockingVetoes,
                rationale: "A blocking veto was issued."
            )
        }

        let nonEmptyVotes = votes.filter { !$0.normalizedChoice.isEmpty }
        guard !nonEmptyVotes.isEmpty else {
            return MagiVerdict(
                kind: .noConsensus,
                votes: votes,
                vetoes: vetoes,
                rationale: "No valid votes were cast."
            )
        }

        let resolvedVotes = nonEmptyVotes.compactMap { resolveVote($0, questionKind: questionKind) }
        guard !resolvedVotes.isEmpty else {
            return MagiVerdict(
                kind: .noConsensus,
                votes: votes,
                vetoes: vetoes,
                rationale: "No valid \(questionKind.rawValue) verdict votes were cast."
            )
        }

        let grouped = Dictionary(grouping: resolvedVotes, by: \.key)
        let ranked = grouped.sorted { lhs, rhs in
            if lhs.value.count == rhs.value.count {
                return lhs.key < rhs.key
            }
            return lhs.value.count > rhs.value.count
        }

        guard let top = ranked.first else {
            return MagiVerdict(kind: .noConsensus, votes: votes, vetoes: vetoes)
        }

        let topVotes = top.value.map(\.vote)
        let tiedTopChoices = ranked.filter { $0.value.count == topVotes.count }
        if topVotes.count >= policy.majorityThreshold, tiedTopChoices.count == 1 {
            let averageConfidence = topVotes.map(\.confidence).reduce(0, +) / Double(topVotes.count)
            let resolved = top.value[0]
            return MagiVerdict(
                kind: resolved.kind,
                decision: resolved.decision,
                consensusScore: Double(topVotes.count) / Double(nonEmptyVotes.count),
                confidence: averageConfidence,
                votes: votes,
                vetoes: vetoes,
                rationale: "Majority reached by \(topVotes.count)/\(nonEmptyVotes.count) votes."
            )
        }

        return MagiVerdict(
            kind: policy.deadlockExtraRoundEnabled ? .deadlock : .noConsensus,
            consensusScore: Double(topVotes.count) / Double(nonEmptyVotes.count),
            votes: votes,
            vetoes: vetoes,
            requiresAdditionalRound: policy.deadlockExtraRoundEnabled,
            rationale: policy.deadlockExtraRoundEnabled ? "No majority reached; one extra round is available." : "No majority reached."
        )
    }

    private struct ResolvedVote {
        var key: String
        var kind: MagiVerdictKind
        var decision: String
        var vote: MagiVote
    }

    private static func resolveVote(_ vote: MagiVote, questionKind: MagiQuestionKind) -> ResolvedVote? {
        let choice = vote.choice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !choice.isEmpty else { return nil }

        switch questionKind {
        case .engineering:
            let kind = vote.verdictKind?.isApprovalStyle == true
                ? vote.verdictKind
                : MagiVerdictKind.inferApprovalStyle(from: choice)
            guard let kind else { return nil }
            return ResolvedVote(
                key: kind.rawValue,
                kind: kind,
                decision: choice.isEmpty ? kind.rawValue : choice,
                vote: vote
            )
        case .generic:
            let kind = vote.verdictKind == .rank ? MagiVerdictKind.rank : .select
            return ResolvedVote(
                key: "\(kind.rawValue):\(vote.normalizedChoice)",
                kind: kind,
                decision: choice,
                vote: vote
            )
        }
    }
}

// MARK: - Graph and Artifacts

public struct MagiDecisionGraph: Codable, Equatable, Sendable {
    public struct Node: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var kind: String
        public var label: String
        public var metadata: [String: String]

        public init(id: String, kind: String, label: String, metadata: [String: String] = [:]) {
            self.id = id
            self.kind = kind
            self.label = label
            self.metadata = metadata
        }
    }

    public struct Edge: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var sourceID: String
        public var targetID: String
        public var label: String?

        public init(id: String, sourceID: String, targetID: String, label: String? = nil) {
            self.id = id
            self.sourceID = sourceID
            self.targetID = targetID
            self.label = label
        }
    }

    public var nodes: [Node]
    public var edges: [Edge]

    public init(nodes: [Node] = [], edges: [Edge] = []) {
        self.nodes = nodes
        self.edges = edges
    }
}

public struct MagiArtifactBundle: Codable, Equatable, Sendable {
    public static let requiredFileNames = [
        "decision.md",
        "decision.json",
        "transcript.jsonl",
        "graph.json",
        "replay.jsonl",
        "share.html"
    ]

    public var runID: String
    public var rootDirectory: String
    public var decisionMarkdownPath: String
    public var decisionJSONPath: String
    public var transcriptJSONLPath: String
    public var graphJSONPath: String
    public var replayJSONLPath: String
    public var shareHTMLPath: String
    public var technicalLogPath: String { "\(rootDirectory)/technical.jsonl" }

    public init(runID: String, rootDirectory: String) {
        let normalizedRoot = Self.normalizedDirectory(rootDirectory)
        self.runID = runID
        self.rootDirectory = normalizedRoot
        self.decisionMarkdownPath = "\(normalizedRoot)/decision.md"
        self.decisionJSONPath = "\(normalizedRoot)/decision.json"
        self.transcriptJSONLPath = "\(normalizedRoot)/transcript.jsonl"
        self.graphJSONPath = "\(normalizedRoot)/graph.json"
        self.replayJSONLPath = "\(normalizedRoot)/replay.jsonl"
        self.shareHTMLPath = "\(normalizedRoot)/share.html"
    }

    public var requiredPaths: [String] {
        [
            decisionMarkdownPath,
            decisionJSONPath,
            transcriptJSONLPath,
            graphJSONPath,
            replayJSONLPath,
            shareHTMLPath
        ]
    }

    public static func rootDirectory(runID: String, repositoryRoot: String?, homeDirectory: String) -> String {
        if let repositoryRoot, !repositoryRoot.isEmpty {
            return "\(normalizedDirectory(repositoryRoot))/.chau7/magi/runs/\(runID)"
        }
        return "\(normalizedDirectory(homeDirectory))/.chau7/magi/runs/\(runID)"
    }

    private static func normalizedDirectory(_ path: String) -> String {
        var result = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.count > 1, result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }
}

public enum MagiRepositoryLocator {
    public static func repositoryRoot(
        startingAt directory: String,
        fileManager: FileManager = .default
    ) -> String? {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var path = (trimmed as NSString).standardizingPath
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue {
            path = (path as NSString).deletingLastPathComponent
        }

        while true {
            let marker = (path as NSString).appendingPathComponent(".git")
            if fileManager.fileExists(atPath: marker) {
                return path
            }

            let parent = (path as NSString).deletingLastPathComponent
            if parent == path || parent.isEmpty {
                return nil
            }
            path = parent
        }
    }
}

public enum MagiRunStatus: String, Codable, CaseIterable, Sendable {
    case configured
    case running
    case waitingForEvidenceApproval
    case completed
    case failed
    case interrupted
}

public enum MagiRunFailureCategory: String, Codable, CaseIterable, Sendable {
    case chau7Unavailable = "chau7_unavailable"
    case mcpSocketMissing = "mcp_socket_missing"
    case providerUnavailable = "provider_unavailable"
    case tabCreationFailed = "tab_creation_failed"
    case agentTimeout = "agent_timeout"
    case malformedJSON = "malformed_json"
    case evidenceDenied = "evidence_denied"
    case veto = "veto"
    case deadlock = "deadlock"
    case interrupted = "interrupted"
    case partialArtifacts = "partial_artifacts"
    case artifactWriteFailed = "artifact_write_failed"
    case unknown
}

public enum MagiRunID {
    public static func make(date: Date = Date(), uuid: UUID = UUID()) -> String {
        let timestamp = DateFormatters.iso8601.string(from: date)
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "Z", with: "z")
        return "magi-\(timestamp)-\(uuid.uuidString.prefix(8).lowercased())"
    }
}

public enum MagiRunStateMachine {
    @discardableResult
    public static func startRound(
        _ run: inout MagiRun,
        id: String,
        index: Int,
        kind: MagiRoundKind,
        at date: Date = Date()
    ) -> MagiRound {
        let round = MagiRound(id: id, index: index, kind: kind, startedAt: date)
        run.rounds.append(round)
        checkpoint(&run, stage: "round:\(id):started", at: date)
        return round
    }

    public static func completeRound(
        _ run: inout MagiRun,
        id: String,
        at date: Date = Date()
    ) {
        guard let index = run.rounds.firstIndex(where: { $0.id == id }) else { return }
        run.rounds[index].completedAt = date
        checkpoint(&run, stage: "round:\(id):completed", at: date)
    }

    public static func checkpoint(
        _ run: inout MagiRun,
        stage: String,
        at date: Date = Date()
    ) {
        run.metadata["last_checkpoint"] = stage
        run.metadata["last_checkpoint_at"] = isoDate(date)
    }

    public static func recordArtifactBundle(
        _ bundle: MagiArtifactBundle,
        in run: inout MagiRun,
        at date: Date = Date()
    ) {
        run.artifactBundle = bundle
        run.metadata["artifact_root"] = bundle.rootDirectory
        run.metadata["artifact_updated_at"] = isoDate(date)
    }

    public static func markFailed(
        _ run: inout MagiRun,
        category: MagiRunFailureCategory,
        stage: String,
        message: String,
        at date: Date = Date()
    ) {
        run.status = .failed
        run.completedAt = date
        run.metadata["failure_category"] = category.rawValue
        run.metadata["failure_stage"] = stage
        run.metadata["error"] = message
        checkpoint(&run, stage: "failed:\(stage)", at: date)
    }

    public static func markInterrupted(
        _ run: inout MagiRun,
        stage: String,
        message: String = "Run interrupted by user.",
        at date: Date = Date()
    ) {
        run.status = .interrupted
        run.completedAt = date
        run.metadata["failure_category"] = MagiRunFailureCategory.interrupted.rawValue
        run.metadata["failure_stage"] = stage
        run.metadata["error"] = message
        checkpoint(&run, stage: "interrupted:\(stage)", at: date)
    }

    public static func recordDeniedEvidenceCount(_ count: Int, in run: inout MagiRun) {
        run.metadata["evidence_denied_count"] = String(max(0, count))
        if count > 0 {
            run.metadata["evidence_denied"] = "true"
        }
    }

    private static func isoDate(_ date: Date) -> String {
        return DateFormatters.iso8601NoFractional.string(from: date)
    }
}

public struct MagiRawTranscript: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var memberID: MagiMemberID
    public var roundID: String
    public var stage: String
    public var tabID: String?
    public var output: String
    public var capturedAt: Date
    public var parseError: String?
    public var repairAttempted: Bool
    public var repairSucceeded: Bool

    public init(
        id: String,
        memberID: MagiMemberID,
        roundID: String,
        stage: String,
        tabID: String? = nil,
        output: String,
        capturedAt: Date = Date(),
        parseError: String? = nil,
        repairAttempted: Bool = false,
        repairSucceeded: Bool = false
    ) {
        self.id = id
        self.memberID = memberID
        self.roundID = roundID
        self.stage = stage
        self.tabID = tabID
        self.output = output
        self.capturedAt = capturedAt
        self.parseError = parseError
        self.repairAttempted = repairAttempted
        self.repairSucceeded = repairSucceeded
    }
}

public struct MagiRun: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var question: String
    public var council: MagiCouncil
    public var status: MagiRunStatus
    public var createdAt: Date
    public var completedAt: Date?
    public var rounds: [MagiRound]
    public var positions: [MagiPosition]
    public var critiques: [MagiCritique]
    public var evidenceRequests: [MagiEvidenceRequest]
    public var evidencePackets: [MagiEvidencePacket]
    public var rawTranscripts: [MagiRawTranscript]
    public var finalVerdict: MagiVerdict?
    public var artifactBundle: MagiArtifactBundle?
    public var metadata: [String: String]

    public init(
        id: String,
        question: String,
        council: MagiCouncil,
        status: MagiRunStatus = .configured,
        createdAt: Date = Date(),
        completedAt: Date? = nil,
        rounds: [MagiRound] = [],
        positions: [MagiPosition] = [],
        critiques: [MagiCritique] = [],
        evidenceRequests: [MagiEvidenceRequest] = [],
        evidencePackets: [MagiEvidencePacket] = [],
        rawTranscripts: [MagiRawTranscript] = [],
        finalVerdict: MagiVerdict? = nil,
        artifactBundle: MagiArtifactBundle? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.question = question
        self.council = council
        self.status = status
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.rounds = rounds
        self.positions = positions
        self.critiques = critiques
        self.evidenceRequests = evidenceRequests
        self.evidencePackets = evidencePackets
        self.rawTranscripts = rawTranscripts
        self.finalVerdict = finalVerdict
        self.artifactBundle = artifactBundle
        self.metadata = metadata
    }
}
