import Foundation

// MARK: - Protocol Markers

public enum MagiProtocolStage: String, Codable, CaseIterable, Sendable {
    case position
    case critique
    case vote

    public var outputName: String {
        switch self {
        case .position: return "POSITION"
        case .critique: return "CRITIQUE"
        case .vote: return "VOTE"
        }
    }
}

public struct MagiProtocolMarkers: Codable, Equatable, Sendable {
    public var begin: String
    public var end: String

    public init(runID: String, roundID: String, memberID: MagiMemberID, stage: MagiProtocolStage) {
        let prefix = "MAGI_\(Self.sanitize(runID))_\(Self.sanitize(roundID))_\(memberID.rawValue.uppercased())_\(stage.outputName)"
        self.begin = "\(prefix)_BEGIN"
        self.end = "\(prefix)_END"
    }

    private static func sanitize(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let scalars = value.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : Character("_")
        }
        return String(scalars).uppercased()
    }
}

// MARK: - Prompt Builder

public enum MagiPromptBuilder {
    public static func independentAnalysisPrompt(
        runID: String,
        roundID: String,
        question: String,
        member: MagiMember
    ) -> String {
        let markers = MagiProtocolMarkers(runID: runID, roundID: roundID, memberID: member.id, stage: .position)
        return """
        MAGI independent analysis
        Run: \(runID)
        Round: \(roundID)
        Member: \(member.persona.displayName)
        Provider: \(member.provider)
        Class: \(member.modelClass.rawValue)
        Reasoning: \(member.reasoning.rawValue)

        Persona lens:
        \(member.persona.lens)

        Persona prompt:
        \(member.persona.prompt)

        Veto policy:
        \(member.persona.vetoPolicy ?? "Use a veto only for rare blocking conditions defined by this persona.")

        Question:
        \(question)

        Rules:
        - Work independently in this round.
        - Do not inspect other MAGI tabs or sibling agents.
        - Use only the question, your persona, and packets explicitly supplied by MAGI.
        - Request evidence instead of collecting it yourself unless MAGI resumes you with approved evidence.
        - Prefer correctness; concise theatrical phrasing is acceptable, but the JSON must be valid.

        Output requirements:
        - End with one JSON object wrapped by these exact marker names.
        - Begin marker name: \(markers.begin)
        - End marker name: \(markers.end)
        - JSON keys: member, round, position, summary, confidence, evidence_requests, veto.
        - member must be "\(member.id.rawValue)".
        - round must be \(roundNumber(from: roundID)).
        - confidence is a number from 0 to 1.
        - evidence_requests is an array of objects with priority, reason, required_evidence, proposed_collectors.
        - proposed_collectors may include local.git_status, local.git_diff, local.repo_search:<query>, local.file_read:<path>, local.command:<command>, or web.query:<query>.
        - veto is null unless your persona veto policy requires a blocking veto; if present use reason, scope, blocks_verdict.

        JSON shape example:
        {
          "member": "\(member.id.rawValue)",
          "round": \(roundNumber(from: roundID)),
          "position": "your answer",
          "summary": "short rationale",
          "confidence": 0.82,
          "evidence_requests": [],
          "veto": null
        }
        """
    }

    public static func councilPacket(
        runID: String,
        question: String,
        positions: [MagiPosition]
    ) -> String {
        var lines: [String] = [
            "MAGI controlled council packet",
            "Run: \(runID)",
            "Share policy: completed outputs only",
            "",
            "Question:",
            question,
            "",
            "Completed member positions:"
        ]

        for position in positions.sorted(by: { $0.memberID.rawValue < $1.memberID.rawValue }) {
            lines.append("")
            lines.append("Member: \(position.memberID.displayName)")
            lines.append("Recommendation: \(position.recommendation)")
            lines.append("Confidence: \(String(format: "%.2f", position.confidence))")
            lines.append("Summary: \(position.summary)")
            if let veto = position.veto {
                lines.append("Veto: \(veto.reason)")
            }
            if !position.evidenceRequests.isEmpty {
                lines.append("Evidence requested:")
                for request in position.evidenceRequests {
                    lines.append("- \(request.priority.rawValue): \(request.reason)")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    public static func critiquePrompt(
        runID: String,
        roundID: String,
        member: MagiMember,
        councilPacket: String
    ) -> String {
        let markers = MagiProtocolMarkers(runID: runID, roundID: roundID, memberID: member.id, stage: .critique)
        return """
        MAGI cross-examination
        Member: \(member.persona.displayName)

        You are receiving a controlled council packet. It is the only sibling-agent material you may use.

        \(councilPacket)

        Critique each other member from your persona. Identify agreements, disagreements, and missing evidence.

        Output requirements:
        - End with one JSON object wrapped by these exact marker names.
        - Begin marker name: \(markers.begin)
        - End marker name: \(markers.end)
        - JSON keys: member, round, critiques, evidence_requests.
        - member must be "\(member.id.rawValue)".
        - round must be \(roundNumber(from: roundID)).
        - critiques is an array; each item must include target_member_id, agreements, disagreements, missing_evidence.
        - evidence_requests is an array using priority, reason, required_evidence, proposed_collectors.

        JSON shape example:
        {
          "member": "\(member.id.rawValue)",
          "round": \(roundNumber(from: roundID)),
          "critiques": [],
          "evidence_requests": []
        }
        """
    }

    public static func finalVotePrompt(
        runID: String,
        roundID: String,
        member: MagiMember,
        councilPacket: String,
        critiques: [MagiCritique],
        evidencePackets: [MagiEvidencePacket],
        questionKind: MagiQuestionKind = .generic
    ) -> String {
        let markers = MagiProtocolMarkers(runID: runID, roundID: roundID, memberID: member.id, stage: .vote)
        let verdictKinds = questionKind.voteVerdictKinds.map(\.rawValue).joined(separator: ", ")
        return """
        MAGI final vote
        Member: \(member.persona.displayName)

        Controlled council packet:
        \(councilPacket)

        Critiques:
        \(formatCritiques(critiques))

        Approved evidence:
        \(formatEvidence(evidencePackets))

        Cast your final vote. Majority is enough. A veto blocks the verdict only when your persona veto policy requires it.
        Verdict mode: \(questionKind.rawValue).
        \(questionKind.promptInstruction)

        Output requirements:
        - End with one JSON object wrapped by these exact marker names.
        - Begin marker name: \(markers.begin)
        - End marker name: \(markers.end)
        - JSON keys: member, round, verdict, vote, confidence, rationale, veto.
        - member must be "\(member.id.rawValue)".
        - round must be \(roundNumber(from: roundID)).
        - verdict must be one of: \(verdictKinds).
        - vote is the final answer you vote for.
        - confidence is a number from 0 to 1.
        - veto is null unless you issue a blocking veto; if present use reason, scope, blocks_verdict.

        JSON shape example:
        {
          "member": "\(member.id.rawValue)",
          "round": \(roundNumber(from: roundID)),
          "verdict": "\(questionKind.voteVerdictKinds[0].rawValue)",
          "vote": "your final answer",
          "confidence": 0.82,
          "rationale": "short rationale",
          "veto": null
        }
        """
    }

    public static func extraRoundPrompt(
        runID: String,
        roundID: String,
        member: MagiMember,
        question: String,
        votes: [MagiVote],
        vetoes: [MagiVeto],
        questionKind: MagiQuestionKind = .generic
    ) -> String {
        let markers = MagiProtocolMarkers(runID: runID, roundID: roundID, memberID: member.id, stage: .vote)
        let voteLines = votes.map {
            let verdict = $0.verdictKind.map { "[\($0.rawValue)] " } ?? ""
            return "- \($0.memberID.displayName): \(verdict)\($0.choice) (\(String(format: "%.2f", $0.confidence))) - \($0.rationale)"
        }.joined(separator: "\n")
        let vetoLines = vetoes.isEmpty
            ? "none"
            : vetoes.map { "- \($0.memberID.displayName): \($0.reason)" }.joined(separator: "\n")
        let verdictKinds = questionKind.voteVerdictKinds.map(\.rawValue).joined(separator: ", ")

        return """
        MAGI extra deliberation
        Member: \(member.persona.displayName)

        Question:
        \(question)

        Current votes:
        \(voteLines)

        Current vetoes:
        \(vetoLines)

        No majority was reached. Reconsider once and cast a final vote.
        Verdict mode: \(questionKind.rawValue).
        \(questionKind.promptInstruction)

        Output requirements:
        - End with one JSON object wrapped by these exact marker names.
        - Begin marker name: \(markers.begin)
        - End marker name: \(markers.end)
        - JSON keys: member, round, verdict, vote, confidence, rationale, veto.
        - member must be "\(member.id.rawValue)".
        - round must be \(roundNumber(from: roundID)).
        - verdict must be one of: \(verdictKinds).
        """
    }

    public static func repairPrompt(
        runID: String,
        roundID: String,
        member: MagiMember,
        stage: MagiProtocolStage,
        parseError: String,
        rawTranscript: String
    ) -> String {
        let markers = MagiProtocolMarkers(runID: runID, roundID: roundID, memberID: member.id, stage: stage)
        return """
        MAGI structured output repair

        Your previous response could not be parsed.
        Parse error:
        \(parseError)

        Extract or repair your own final answer from the raw transcript below. Do not add new analysis.
        Return exactly one parseable JSON block wrapped by the required markers.

        Required begin marker name: \(markers.begin)
        Required end marker name: \(markers.end)

        Required member:
        \(member.id.rawValue)

        Required round:
        \(roundNumber(from: roundID))

        Required stage:
        \(stage.outputName)

        Raw transcript:
        \(rawTranscript)
        """
    }

    public static func roundNumber(from roundID: String) -> Int {
        let digits = roundID.split(whereSeparator: { !$0.isNumber }).last
        return digits.flatMap { Int($0) } ?? 0
    }

    private static func formatCritiques(_ critiques: [MagiCritique]) -> String {
        guard !critiques.isEmpty else { return "none" }
        return critiques.map { critique in
            """
            Critic: \(critique.criticMemberID.displayName)
            Target: \(critique.targetMemberID.displayName)
            Agreements: \(critique.agreements.joined(separator: "; "))
            Disagreements: \(critique.disagreements.joined(separator: "; "))
            Missing evidence: \(critique.missingEvidence.joined(separator: "; "))
            """
        }.joined(separator: "\n\n")
    }

    private static func formatEvidence(_ packets: [MagiEvidencePacket]) -> String {
        guard !packets.isEmpty else { return "none" }
        return packets.map { packet in
            """
            Collector: \(packet.collectorID)
            Source: \(packet.sourceDescription)
            Summary: \(packet.summary)
            Content:
            \(packet.content)
            """
        }.joined(separator: "\n\n")
    }
}

// MARK: - Persona Files

public enum MagiPersonaFileParser {
    public static func parse(memberID: MagiMemberID, content: String) -> MagiPersona {
        let defaults = MagiPersona.defaultPersonasByID[memberID] ?? MagiPersona(
            memberID: memberID,
            lens: "General MAGI council judgment.",
            prompt: "Evaluate the question through this member's configured judgment lens."
        )
        let metadata = parseMetadata(content)
        return MagiPersona(
            memberID: memberID,
            displayName: metadata["display_name"].flatMap(nonEmpty) ?? defaults.displayName,
            lens: metadata["lens"].flatMap(nonEmpty) ?? defaults.lens,
            prompt: section(named: "Operating Prompt", in: content).flatMap(nonEmpty) ?? defaults.prompt,
            vetoPolicy: section(named: "Veto Policy", in: content).flatMap(nonEmpty) ?? defaults.vetoPolicy,
            isUserEditable: bool(metadata["editable"]) ?? defaults.isUserEditable
        )
    }

    private static func parseMetadata(_ content: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.hasPrefix("#"), let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            values[key] = value
        }
        return values
    }

    private static func section(named name: String, in content: String) -> String? {
        let lines = content.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "## \(name)" }) else {
            return nil
        }

        let bodyStart = lines.index(after: start)
        let bodyEnd = lines[bodyStart...].firstIndex { line in
            line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("## ")
        } ?? lines.endIndex

        return lines[bodyStart ..< bodyEnd]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func bool(_ value: String?) -> Bool? {
        switch value?.lowercased() {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default: return nil
        }
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Transcript Parsing

public enum MagiTranscriptParseError: Error, Equatable, LocalizedError {
    case missingBlock(begin: String, end: String)
    case invalidJSON(begin: String, reason: String)
    case invalidContract(reason: String)

    public var errorDescription: String? {
        switch self {
        case let .missingBlock(begin, end):
            return "Missing MAGI output block \(begin) ... \(end)."
        case let .invalidJSON(begin, reason):
            return "Invalid MAGI JSON block \(begin): \(reason)"
        case let .invalidContract(reason):
            return "Invalid MAGI output contract: \(reason)"
        }
    }
}

public enum MagiTranscriptParser {
    public static func parsePosition(
        memberID: MagiMemberID,
        roundID: String,
        output: String,
        markers: MagiProtocolMarkers
    ) throws -> MagiPosition {
        let payload = try decodeLatestBlock(PositionPayload.self, from: output, markers: markers)
        try validateContract(memberID: memberID, roundID: roundID, member: payload.member, round: payload.round)
        let requests = payload.evidenceRequests.enumerated().map { index, request in
            MagiEvidenceRequest(
                id: "\(roundID)-\(memberID.rawValue)-evidence-\(index + 1)",
                memberID: memberID,
                roundID: roundID,
                priority: request.priorityValue,
                reason: request.reason,
                requiredEvidence: request.requiredEvidence,
                proposedCollectors: request.proposedCollectors
            )
        }
        let veto = payload.veto?.model(id: "\(roundID)-\(memberID.rawValue)-veto", memberID: memberID)
        return MagiPosition(
            id: "\(roundID)-\(memberID.rawValue)-position",
            memberID: memberID,
            roundID: roundID,
            recommendation: payload.position,
            summary: payload.summary,
            confidence: payload.confidence,
            evidenceRequests: requests,
            veto: veto,
            rawOutput: output
        )
    }

    public static func parseCritiques(
        criticMemberID: MagiMemberID,
        roundID: String,
        output: String,
        markers: MagiProtocolMarkers
    ) throws -> (critiques: [MagiCritique], evidenceRequests: [MagiEvidenceRequest]) {
        let block = try decodeLatestBlock(CritiqueBlockPayload.self, from: output, markers: markers)
        try validateContract(memberID: criticMemberID, roundID: roundID, member: block.member, round: block.round)
        var evidenceRequests: [MagiEvidenceRequest] = block.evidenceRequests.enumerated().map { index, request in
            MagiEvidenceRequest(
                id: "\(roundID)-\(criticMemberID.rawValue)-evidence-\(index + 1)",
                memberID: criticMemberID,
                roundID: roundID,
                priority: request.priorityValue,
                reason: request.reason,
                requiredEvidence: request.requiredEvidence,
                proposedCollectors: request.proposedCollectors
            )
        }
        let critiques = block.critiques.enumerated().compactMap { critiqueIndex, payload -> MagiCritique? in
            guard let targetMemberID = MagiMemberID(rawValue: payload.targetMemberID) else { return nil }
            for (requestIndex, request) in payload.evidenceRequests.enumerated() {
                evidenceRequests.append(
                    MagiEvidenceRequest(
                        id: "\(roundID)-\(criticMemberID.rawValue)-critique-\(critiqueIndex + 1)-evidence-\(requestIndex + 1)",
                        memberID: criticMemberID,
                        roundID: roundID,
                        priority: request.priorityValue,
                        reason: request.reason,
                        requiredEvidence: request.requiredEvidence,
                        proposedCollectors: request.proposedCollectors
                    )
                )
            }
            return MagiCritique(
                id: "\(roundID)-\(criticMemberID.rawValue)-\(targetMemberID.rawValue)-critique",
                criticMemberID: criticMemberID,
                targetMemberID: targetMemberID,
                roundID: roundID,
                agreements: payload.agreements,
                disagreements: payload.disagreements,
                missingEvidence: payload.missingEvidence,
                rawOutput: output
            )
        }
        return (critiques, evidenceRequests)
    }

    public static func parseVote(
        memberID: MagiMemberID,
        roundID: String,
        output: String,
        markers: MagiProtocolMarkers
    ) throws -> (vote: MagiVote, veto: MagiVeto?) {
        let payload = try decodeLatestBlock(VotePayload.self, from: output, markers: markers)
        try validateContract(memberID: memberID, roundID: roundID, member: payload.member, round: payload.round)
        return (
            vote: MagiVote(
                id: "\(roundID)-\(memberID.rawValue)-vote",
                memberID: memberID,
                verdictKind: payload.verdictKind,
                choice: payload.vote,
                confidence: payload.confidence,
                rationale: payload.rationale,
                rawOutput: output
            ),
            veto: payload.veto?.model(id: "\(roundID)-\(memberID.rawValue)-vote-veto", memberID: memberID)
        )
    }

    public static func blockCandidates(in output: String, markers: MagiProtocolMarkers) -> [String] {
        var candidates: [String] = []
        var body: [String] = []
        var isCollecting = false

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == markers.begin {
                isCollecting = true
                body = []
                continue
            }

            if isCollecting, trimmed == markers.end {
                candidates.append(
                    body.joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                )
                isCollecting = false
                body = []
                continue
            }

            if isCollecting {
                body.append(line)
            }
        }

        return candidates
    }

    private static func decodeLatestBlock<T: Decodable>(
        _: T.Type,
        from output: String,
        markers: MagiProtocolMarkers
    ) throws -> T {
        let candidates = blockCandidates(in: output, markers: markers)
        guard !candidates.isEmpty else {
            throw MagiTranscriptParseError.missingBlock(begin: markers.begin, end: markers.end)
        }

        let candidate = candidates[candidates.count - 1]
        guard let data = candidate.data(using: .utf8) else {
            throw MagiTranscriptParseError.invalidJSON(begin: markers.begin, reason: "block is not UTF-8")
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw MagiTranscriptParseError.invalidJSON(
                begin: markers.begin,
                reason: String(describing: error)
            )
        }
    }

    private static func validateContract(
        memberID: MagiMemberID,
        roundID: String,
        member: String,
        round: Int
    ) throws {
        guard member.lowercased() == memberID.rawValue else {
            throw MagiTranscriptParseError.invalidContract(
                reason: "expected member \(memberID.rawValue), got \(member)"
            )
        }

        let expectedRound = MagiPromptBuilder.roundNumber(from: roundID)
        guard round == expectedRound else {
            throw MagiTranscriptParseError.invalidContract(
                reason: "expected round \(expectedRound), got \(round)"
            )
        }
    }
}

private struct PositionPayload: Decodable {
    var member: String
    var round: Int
    var position: String
    var summary: String
    var confidence: Double
    var evidenceRequests: [EvidenceRequestPayload]
    var veto: VetoPayload?

    enum CodingKeys: String, CodingKey {
        case member
        case round
        case position
        case recommendation
        case summary
        case confidence
        case evidenceRequests = "evidence_requests"
        case veto
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.member = try container.decode(String.self, forKey: .member)
        self.round = try container.decode(Int.self, forKey: .round)
        self.position = try container.decodeIfPresent(String.self, forKey: .position)
            ?? container.decode(String.self, forKey: .recommendation)
        self.summary = try container.decode(String.self, forKey: .summary)
        self.confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
        self.evidenceRequests = try container.decodeIfPresent([EvidenceRequestPayload].self, forKey: .evidenceRequests) ?? []
        self.veto = try container.decodeIfPresent(VetoPayload.self, forKey: .veto)
    }
}

private struct CritiqueBlockPayload: Decodable {
    var member: String
    var round: Int
    var critiques: [CritiquePayload]
    var evidenceRequests: [EvidenceRequestPayload]

    enum CodingKeys: String, CodingKey {
        case member
        case round
        case critiques
        case evidenceRequests = "evidence_requests"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.member = try container.decode(String.self, forKey: .member)
        self.round = try container.decode(Int.self, forKey: .round)
        self.critiques = try container.decodeIfPresent([CritiquePayload].self, forKey: .critiques) ?? []
        self.evidenceRequests = try container.decodeIfPresent([EvidenceRequestPayload].self, forKey: .evidenceRequests) ?? []
    }
}

private struct CritiquePayload: Decodable {
    var targetMemberID: String
    var agreements: [String]
    var disagreements: [String]
    var missingEvidence: [String]
    var evidenceRequests: [EvidenceRequestPayload]

    enum CodingKeys: String, CodingKey {
        case targetMemberID = "target_member_id"
        case agreements
        case disagreements
        case missingEvidence = "missing_evidence"
        case evidenceRequests = "evidence_requests"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.targetMemberID = try container.decode(String.self, forKey: .targetMemberID)
        self.agreements = try container.decodeIfPresent([String].self, forKey: .agreements) ?? []
        self.disagreements = try container.decodeIfPresent([String].self, forKey: .disagreements) ?? []
        self.missingEvidence = try container.decodeIfPresent([String].self, forKey: .missingEvidence) ?? []
        self.evidenceRequests = try container.decodeIfPresent([EvidenceRequestPayload].self, forKey: .evidenceRequests) ?? []
    }
}

private struct VotePayload: Decodable {
    var member: String
    var round: Int
    var verdictKind: MagiVerdictKind?
    var vote: String
    var confidence: Double
    var rationale: String
    var veto: VetoPayload?

    enum CodingKeys: String, CodingKey {
        case member
        case round
        case verdict
        case verdictKind = "verdict_kind"
        case kind
        case vote
        case choice
        case confidence
        case rationale
        case veto
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.member = try container.decode(String.self, forKey: .member)
        self.round = try container.decode(Int.self, forKey: .round)
        let verdictLabel = try container.decodeIfPresent(String.self, forKey: .verdict)
            ?? container.decodeIfPresent(String.self, forKey: .verdictKind)
            ?? container.decodeIfPresent(String.self, forKey: .kind)
        if let verdictLabel {
            guard let parsed = MagiVerdictKind.parse(verdictLabel) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .verdict,
                    in: container,
                    debugDescription: "Unsupported MAGI verdict kind: \(verdictLabel)"
                )
            }
            self.verdictKind = parsed
        } else {
            self.verdictKind = nil
        }
        self.vote = try container.decodeIfPresent(String.self, forKey: .vote)
            ?? container.decode(String.self, forKey: .choice)
        self.confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
        self.rationale = try container.decodeIfPresent(String.self, forKey: .rationale) ?? ""
        self.veto = try container.decodeIfPresent(VetoPayload.self, forKey: .veto)
    }
}

private struct EvidenceRequestPayload: Decodable {
    var priority: String
    var reason: String
    var requiredEvidence: [String]
    var proposedCollectors: [String]

    enum CodingKeys: String, CodingKey {
        case priority
        case reason
        case requiredEvidence = "required_evidence"
        case proposedCollectors = "proposed_collectors"
    }

    var priorityValue: MagiEvidencePriority {
        MagiEvidencePriority(rawValue: priority) ?? .medium
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.priority = try container.decodeIfPresent(String.self, forKey: .priority) ?? MagiEvidencePriority.medium.rawValue
        self.reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? ""
        self.requiredEvidence = try container.decodeIfPresent([String].self, forKey: .requiredEvidence) ?? []
        self.proposedCollectors = try container.decodeIfPresent([String].self, forKey: .proposedCollectors) ?? []
    }
}

private struct VetoPayload: Decodable {
    var reason: String
    var scope: String
    var blocksVerdict: Bool

    enum CodingKeys: String, CodingKey {
        case reason
        case scope
        case blocksVerdict = "blocks_verdict"
    }

    func model(id: String, memberID: MagiMemberID) -> MagiVeto {
        MagiVeto(
            id: id,
            memberID: memberID,
            reason: reason,
            scope: scope,
            blocksVerdict: blocksVerdict
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? ""
        self.scope = try container.decodeIfPresent(String.self, forKey: .scope) ?? "run"
        self.blocksVerdict = try container.decodeIfPresent(Bool.self, forKey: .blocksVerdict) ?? true
    }
}

// MARK: - Evidence Collectors

public struct MagiCollectorCommand: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var collectorKind: MagiEvidenceCollectorKind
    public var payload: String?
    public var command: String
    public var sourceDescription: String
    public var requiresMCPCommandPermission: Bool

    public init(
        id: String,
        collectorKind: MagiEvidenceCollectorKind,
        payload: String? = nil,
        command: String,
        sourceDescription: String,
        requiresMCPCommandPermission: Bool = true
    ) {
        self.id = id
        self.collectorKind = collectorKind
        self.payload = payload
        self.command = command
        self.sourceDescription = sourceDescription
        self.requiresMCPCommandPermission = requiresMCPCommandPermission
    }

    public var usesWeb: Bool {
        collectorKind == .webQuery
    }
}

public enum MagiEvidenceCollectorPlanner {
    public static func commands(for request: MagiEvidenceRequest) -> [MagiCollectorCommand] {
        let collectors = request.proposedCollectors.isEmpty ? ["local.git_status"] : request.proposedCollectors
        return collectors.enumerated().map { index, collector in
            let trimmed = collector.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = "\(request.id)-collector-\(index + 1)"
            switch trimmed {
            case "local.git_status":
                return MagiCollectorCommand(
                    id: id,
                    collectorKind: .localGitStatus,
                    command: "git status --short",
                    sourceDescription: "git status --short"
                )
            case "local.git_diff":
                return MagiCollectorCommand(
                    id: id,
                    collectorKind: .localGitDiff,
                    command: "git diff --color=never",
                    sourceDescription: "git diff"
                )
            default:
                if let query = commandPayload(prefix: "local.repo_search:", collector: trimmed) {
                    return MagiCollectorCommand(
                        id: id,
                        collectorKind: .localRepoSearch,
                        payload: query,
                        command: "rg -n --hidden --glob '!.git/*' -- \(shellQuote(query)) . | head -200",
                        sourceDescription: "repository search"
                    )
                }
                if let path = commandPayload(prefix: "local.file_read:", collector: trimmed) {
                    return MagiCollectorCommand(
                        id: id,
                        collectorKind: .localFileRead,
                        payload: path,
                        command: "sed -n '1,240p' \(shellQuote(path))",
                        sourceDescription: "file read"
                    )
                }
                if let command = commandPayload(prefix: "local.command:", collector: trimmed) {
                    return MagiCollectorCommand(
                        id: id,
                        collectorKind: .localCommand,
                        payload: command,
                        command: command,
                        sourceDescription: "approved local command"
                    )
                }
                if let query = commandPayload(prefix: "web.query:", collector: trimmed) {
                    return MagiCollectorCommand(
                        id: id,
                        collectorKind: .webQuery,
                        payload: query,
                        command: webQueryCommand(query: query),
                        sourceDescription: "web query"
                    )
                }
                return MagiCollectorCommand(
                    id: id,
                    collectorKind: .unsupported,
                    payload: trimmed,
                    command: "printf '%s\\n' 'Unsupported MAGI collector: \(shellEscaped(trimmed))'",
                    sourceDescription: "unsupported collector",
                    requiresMCPCommandPermission: false
                )
            }
        }
    }

    private static func commandPayload(prefix: String, collector: String) -> String? {
        guard collector.hasPrefix(prefix) else { return nil }
        let payload = String(collector.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return payload.isEmpty ? nil : payload
    }

    private static func shellEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "'\\''")
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(shellEscaped(value))'"
    }

    private static func webQueryCommand(query: String) -> String {
        let script = """
        import html
        import os
        import re
        import sys
        import urllib.parse
        import urllib.request

        query = os.environ["MAGI_WEB_QUERY"]
        url = "https://duckduckgo.com/html/?q=" + urllib.parse.quote(query)
        request = urllib.request.Request(
            url,
            headers={"User-Agent": "Chau7 MAGI evidence collector/1.0"}
        )
        with urllib.request.urlopen(request, timeout=20) as response:
            document = response.read(200000).decode("utf-8", "replace")
        document = re.sub(r"(?is)<(script|style).*?</\\1>", " ", document)
        document = re.sub(r"(?s)<[^>]+>", "\\n", document)
        lines = [
            line.strip()
            for line in html.unescape(document).splitlines()
            if line.strip()
        ]
        sys.stdout.write("Query: " + query + "\\n")
        sys.stdout.write("URL: " + url + "\\n")
        for line in lines[:80]:
            sys.stdout.write(line[:500] + "\\n")
        """
        return "MAGI_WEB_QUERY=\(shellQuote(query)) /usr/bin/python3 -c \(shellQuote(script))"
    }
}
