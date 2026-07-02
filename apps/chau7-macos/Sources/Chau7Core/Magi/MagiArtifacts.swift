import Foundation

public enum MagiRunArtifactRenderer {
    public static func decisionMarkdown(for run: MagiRun) -> String {
        let verdict = run.finalVerdict
        var lines: [String] = [
            "# MAGI Decision",
            "",
            "Run: \(run.id)",
            "Status: \(run.status.rawValue)",
            "",
            "## Question",
            "",
            run.question,
            "",
            "## Verdict",
            "",
            "Kind: \(verdict?.kind.rawValue ?? "UNKNOWN")"
        ]
        if let decision = verdict?.decision {
            lines.append("Decision: \(decision)")
        }
        if let verdict {
            lines.append("Consensus: \(formatScore(verdict.consensusScore))")
            lines.append("Confidence: \(formatScore(verdict.confidence))")
            if !verdict.rationale.isEmpty {
                lines.append("Rationale: \(verdict.rationale)")
            }
            lines.append("")
            lines.append("## Votes")
            lines.append("")
            for vote in verdict.votes {
                let voteKind = vote.verdictKind.map { "[\($0.rawValue)] " } ?? ""
                lines.append("- \(vote.memberID.displayName): \(voteKind)\(vote.choice) (\(formatScore(vote.confidence)))")
            }
            if !verdict.vetoes.isEmpty {
                lines.append("")
                lines.append("## Vetoes")
                lines.append("")
                for veto in verdict.vetoes {
                    lines.append("- \(veto.memberID.displayName): \(veto.reason)")
                }
            }
        }
        if run.status == .failed || run.status == .interrupted {
            lines.append("")
            lines.append("## Failure")
            lines.append("")
            lines.append("Category: \(run.metadata["failure_category"] ?? "unknown")")
            lines.append("Stage: \(run.metadata["failure_stage"] ?? run.metadata["last_checkpoint"] ?? "unknown")")
            if let error = run.metadata["error"], !error.isEmpty {
                lines.append("Error: \(error)")
            }
            if let checkpoint = run.metadata["last_checkpoint"], !checkpoint.isEmpty {
                lines.append("Last checkpoint: \(checkpoint)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func transcriptJSONL(for run: MagiRun) -> String {
        var lines: [String] = []
        for transcript in run.rawTranscripts {
            lines.append(jsonLine([
                "type": "raw_transcript",
                "id": transcript.id,
                "member_id": transcript.memberID.rawValue,
                "round_id": transcript.roundID,
                "stage": transcript.stage,
                "tab_id": transcript.tabID ?? "",
                "captured_at": isoDate(transcript.capturedAt),
                "output": transcript.output,
                "parse_error": transcript.parseError ?? "",
                "repair_attempted": String(transcript.repairAttempted),
                "repair_succeeded": String(transcript.repairSucceeded)
            ]))
        }
        for position in run.positions {
            lines.append(jsonLine([
                "type": "position",
                "id": position.id,
                "member_id": position.memberID.rawValue,
                "round_id": position.roundID,
                "recommendation": position.recommendation,
                "summary": position.summary,
                "confidence": formatScore(position.confidence)
            ]))
        }
        for critique in run.critiques {
            lines.append(jsonLine([
                "type": "critique",
                "id": critique.id,
                "critic_member_id": critique.criticMemberID.rawValue,
                "target_member_id": critique.targetMemberID.rawValue,
                "round_id": critique.roundID,
                "agreements": critique.agreements.joined(separator: " | "),
                "disagreements": critique.disagreements.joined(separator: " | "),
                "missing_evidence": critique.missingEvidence.joined(separator: " | ")
            ]))
        }
        for request in run.evidenceRequests {
            lines.append(jsonLine([
                "type": "evidence_request",
                "id": request.id,
                "member_id": request.memberID.rawValue,
                "round_id": request.roundID,
                "priority": request.priority.rawValue,
                "status": request.status.rawValue,
                "reason": request.reason,
                "required_evidence": request.requiredEvidence.joined(separator: " | "),
                "proposed_collectors": request.proposedCollectors.joined(separator: ",")
            ]))
        }
        for packet in run.evidencePackets {
            lines.append(jsonLine([
                "type": "evidence",
                "id": packet.id,
                "collector_id": packet.collectorID,
                "request_id": packet.requestID ?? "",
                "captured_at": isoDate(packet.capturedAt),
                "summary": packet.summary,
                "source_description": packet.sourceDescription,
                "collector_kind": packet.metadata["collector_kind"] ?? "",
                "collection_status": packet.metadata["collection_status"] ?? "",
                "web_access": packet.metadata["web_access"] ?? "",
                "web_access_allowed": packet.metadata["web_access_allowed"] ?? "",
                "query": packet.metadata["query"] ?? ""
            ]))
        }
        if let verdict = run.finalVerdict {
            for vote in verdict.votes {
                lines.append(jsonLine([
                    "type": "vote",
                    "id": vote.id,
                    "member_id": vote.memberID.rawValue,
                    "verdict_kind": vote.verdictKind?.rawValue ?? "",
                    "choice": vote.choice,
                    "confidence": formatScore(vote.confidence),
                    "rationale": vote.rationale
                ]))
            }
            for veto in verdict.vetoes {
                lines.append(jsonLine([
                    "type": "veto",
                    "id": veto.id,
                    "member_id": veto.memberID.rawValue,
                    "reason": veto.reason,
                    "scope": veto.scope,
                    "blocks_verdict": String(veto.blocksVerdict)
                ]))
            }
            lines.append(jsonLine([
                "type": "verdict",
                "kind": verdict.kind.rawValue,
                "decision": verdict.decision ?? "",
                "consensus": formatScore(verdict.consensusScore),
                "confidence": formatScore(verdict.confidence),
                "rationale": verdict.rationale
            ]))
        }
        if run.status == .failed || run.status == .interrupted {
            lines.append(jsonLine([
                "type": "failure",
                "status": run.status.rawValue,
                "category": run.metadata["failure_category"] ?? "unknown",
                "stage": run.metadata["failure_stage"] ?? run.metadata["last_checkpoint"] ?? "unknown",
                "error": run.metadata["error"] ?? "",
                "last_checkpoint": run.metadata["last_checkpoint"] ?? ""
            ]))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func replayJSONL(for run: MagiRun) -> String {
        var lines: [String] = []
        var order = 0
        func append(_ fields: [String: String]) {
            order += 1
            var event = fields
            event["order"] = String(format: "%04d", order)
            lines.append(jsonLine(event))
        }

        append([
            "type": "run",
            "title": "Run started",
            "detail": run.question,
            "run_id": run.id,
            "status": run.status.rawValue,
            "created_at": isoDate(run.createdAt)
        ])

        let sortedRounds = run.rounds.sorted { $0.index < $1.index }
        let hasEvidenceCollectionRound = sortedRounds.contains { $0.kind == .evidenceCollection }
        let requestByID = Dictionary(uniqueKeysWithValues: run.evidenceRequests.map { ($0.id, $0) })
        let voteRoundID = sortedRounds.last { $0.kind == .extraDeliberation }?.id
            ?? sortedRounds.last { $0.kind == .vote }?.id

        for round in sortedRounds {
            append([
                "type": "round",
                "title": "Round \(round.index): \(roundTitle(round.kind))",
                "detail": "Share policy: \(round.kind.sharePolicy.rawValue)",
                "round_id": round.id,
                "round_kind": round.kind.rawValue,
                "started_at": isoDate(round.startedAt),
                "completed_at": round.completedAt.map(isoDate) ?? ""
            ])

            for position in run.positions.filter({ $0.roundID == round.id }) {
                append([
                    "type": "position",
                    "title": "\(position.memberID.displayName) position",
                    "detail": position.recommendation,
                    "member_id": position.memberID.rawValue,
                    "round_id": position.roundID,
                    "summary": position.summary,
                    "confidence": formatScore(position.confidence)
                ])
                if let veto = position.veto {
                    append([
                        "type": "veto",
                        "title": "\(veto.memberID.displayName) veto",
                        "detail": veto.reason,
                        "member_id": veto.memberID.rawValue,
                        "round_id": position.roundID,
                        "blocks_verdict": String(veto.blocksVerdict)
                    ])
                }
            }

            for critique in run.critiques.filter({ $0.roundID == round.id }) {
                append([
                    "type": "critique",
                    "title": "\(critique.criticMemberID.displayName) critiques \(critique.targetMemberID.displayName)",
                    "detail": critiqueSummary(critique),
                    "member_id": critique.criticMemberID.rawValue,
                    "target_member_id": critique.targetMemberID.rawValue,
                    "round_id": critique.roundID
                ])
            }

            for request in run.evidenceRequests.filter({ $0.roundID == round.id }) {
                append([
                    "type": "evidence_request",
                    "title": "\(request.memberID.displayName) requests evidence",
                    "detail": request.reason,
                    "member_id": request.memberID.rawValue,
                    "round_id": request.roundID,
                    "request_id": request.id,
                    "priority": request.priority.rawValue,
                    "status": request.status.rawValue,
                    "collectors": request.proposedCollectors.joined(separator: ",")
                ])
            }

            let packetsForRound = run.evidencePackets.filter { packet in
                if round.kind == .evidenceCollection {
                    return true
                }
                guard !hasEvidenceCollectionRound else {
                    return false
                }
                if let requestID = packet.requestID, let request = requestByID[requestID] {
                    return request.roundID == round.id
                }
                return false
            }
            for packet in packetsForRound {
                append([
                    "type": "evidence",
                    "title": "Evidence from \(packet.collectorID)",
                    "detail": packet.summary,
                    "round_id": round.id,
                    "request_id": packet.requestID ?? "",
                    "collector_id": packet.collectorID,
                    "source_description": packet.sourceDescription,
                    "collection_status": packet.metadata["collection_status"] ?? ""
                ])
            }

            if voteRoundID == round.id, let verdict = run.finalVerdict {
                for vote in verdict.votes {
                    append([
                        "type": "vote",
                        "title": "\(vote.memberID.displayName) vote",
                        "detail": vote.choice,
                        "member_id": vote.memberID.rawValue,
                        "round_id": round.id,
                        "verdict_kind": vote.verdictKind?.rawValue ?? "",
                        "confidence": formatScore(vote.confidence),
                        "rationale": vote.rationale
                    ])
                }
                for veto in verdict.vetoes {
                    append([
                        "type": "veto",
                        "title": "\(veto.memberID.displayName) veto",
                        "detail": veto.reason,
                        "member_id": veto.memberID.rawValue,
                        "round_id": round.id,
                        "blocks_verdict": String(veto.blocksVerdict)
                    ])
                }
            }
        }

        if sortedRounds.isEmpty {
            for position in run.positions {
                append([
                    "type": "position",
                    "title": "\(position.memberID.displayName) position",
                    "detail": position.recommendation,
                    "member_id": position.memberID.rawValue,
                    "round_id": position.roundID
                ])
            }
        }

        if let verdict = run.finalVerdict {
            append([
                "type": "verdict",
                "title": "Final verdict: \(verdict.kind.rawValue)",
                "detail": verdict.decision ?? verdict.rationale,
                "kind": verdict.kind.rawValue,
                "decision": verdict.decision ?? "",
                "consensus": formatScore(verdict.consensusScore),
                "confidence": formatScore(verdict.confidence)
            ])
        }

        if run.status == .failed || run.status == .interrupted {
            append([
                "type": "failure",
                "title": run.status == .interrupted ? "Run interrupted" : "Run failed",
                "detail": run.metadata["error"] ?? "",
                "status": run.status.rawValue,
                "category": run.metadata["failure_category"] ?? "unknown",
                "stage": run.metadata["failure_stage"] ?? run.metadata["last_checkpoint"] ?? "unknown",
                "last_checkpoint": run.metadata["last_checkpoint"] ?? ""
            ])
        }

        return lines.joined(separator: "\n") + "\n"
    }

    public static func graphJSON(for run: MagiRun) -> String {
        var graph = MagiDecisionGraph()
        var runMetadata = run.metadata
        runMetadata["status"] = run.status.rawValue
        runMetadata["created_at"] = isoDate(run.createdAt)
        graph.nodes.append(.init(
            id: run.id,
            kind: "run",
            label: run.question,
            metadata: runMetadata
        ))
        for round in run.rounds {
            graph.nodes.append(.init(
                id: round.id,
                kind: "round",
                label: "Round \(round.index): \(roundTitle(round.kind))",
                metadata: [
                    "round_kind": round.kind.rawValue,
                    "share_policy": round.kind.sharePolicy.rawValue
                ]
            ))
            graph.edges.append(.init(
                id: "\(run.id)-\(round.id)",
                sourceID: run.id,
                targetID: round.id,
                label: "round"
            ))
        }
        for position in run.positions {
            graph.nodes.append(.init(
                id: position.id,
                kind: "position",
                label: position.recommendation,
                metadata: [
                    "member_id": position.memberID.rawValue,
                    "confidence": formatScore(position.confidence)
                ]
            ))
            graph.edges.append(.init(
                id: "\(position.roundID)-\(position.id)",
                sourceID: position.roundID,
                targetID: position.id,
                label: position.memberID.rawValue
            ))
        }
        for critique in run.critiques {
            graph.nodes.append(.init(
                id: critique.id,
                kind: "critique",
                label: "\(critique.criticMemberID.displayName) -> \(critique.targetMemberID.displayName)",
                metadata: [
                    "critic_member_id": critique.criticMemberID.rawValue,
                    "target_member_id": critique.targetMemberID.rawValue
                ]
            ))
            graph.edges.append(.init(
                id: "\(critique.roundID)-\(critique.id)",
                sourceID: critique.roundID,
                targetID: critique.id,
                label: "critique"
            ))
        }
        if let verdict = run.finalVerdict {
            graph.nodes.append(.init(
                id: "\(run.id)-verdict",
                kind: "verdict",
                label: verdict.decision ?? verdict.kind.rawValue,
                metadata: [
                    "kind": verdict.kind.rawValue,
                    "consensus": formatScore(verdict.consensusScore),
                    "confidence": formatScore(verdict.confidence)
                ]
            ))
            graph.edges.append(.init(
                id: "\(run.id)-verdict-edge",
                sourceID: run.id,
                targetID: "\(run.id)-verdict",
                label: verdict.kind.rawValue
            ))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(graph) {
            return String(decoding: data, as: UTF8.self) + "\n"
        }
        return "{}\n"
    }

    public static func shareHTML(for run: MagiRun) -> String {
        let verdict = run.finalVerdict
        let decision = verdict?.decision ?? verdict?.kind.rawValue ?? "UNKNOWN"
        let votesHTML = verdict?.votes.map { vote in
            let verdictKind = vote.verdictKind.map { "\($0.rawValue) " } ?? ""
            return """
            <li><strong>\(htmlEscape(vote.memberID.displayName))</strong><span>\(htmlEscape(verdictKind + vote.choice))</span><small>confidence \(formatScore(vote.confidence))</small><p>\(htmlEscape(vote.rationale))</p></li>
            """
        }.joined(separator: "\n") ?? "<li>No votes recorded.</li>"
        let positionsHTML = run.positions.isEmpty
            ? "<li>No positions recorded.</li>"
            : run.positions.map { position in
                """
                <li><strong>\(htmlEscape(position.memberID.displayName))</strong><span>\(htmlEscape(position.recommendation))</span><small>confidence \(formatScore(position.confidence))</small><p>\(htmlEscape(position.summary))</p></li>
                """
            }.joined(separator: "\n")
        let evidenceHTML = run.evidencePackets.isEmpty
            ? "<li>No evidence packets recorded.</li>"
            : run.evidencePackets.map { packet in
                """
                <li><strong>\(htmlEscape(packet.collectorID))</strong><span>\(htmlEscape(packet.summary))</span><small>\(htmlEscape(packet.sourceDescription))</small></li>
                """
            }.joined(separator: "\n")
        let councilHTML = run.council.members.map { member in
            """
            <li><strong>\(htmlEscape(member.persona.displayName))</strong><span>\(htmlEscape(member.provider)) / \(htmlEscape(member.modelClass.rawValue))</span><small>\(htmlEscape(member.persona.lens))</small></li>
            """
        }.joined(separator: "\n")
        let failureHTML: String
        if run.status == .failed || run.status == .interrupted {
            let category = run.metadata["failure_category"] ?? "unknown"
            let stage = run.metadata["failure_stage"] ?? run.metadata["last_checkpoint"] ?? "unknown"
            let error = run.metadata["error"] ?? ""
            failureHTML = """
            <section>
              <article>
                <h2>Failure</h2>
                <p><strong>\(htmlEscape(category))</strong> at \(htmlEscape(stage))</p>
                <p>\(htmlEscape(error))</p>
              </article>
            </section>
            """
        } else {
            failureHTML = ""
        }

        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>MAGI \(htmlEscape(run.id))</title>
          <style>
            :root { color-scheme: light dark; font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: #f6f6f3; color: #171717; }
            body { margin: 0; }
            main { max-width: 980px; margin: 0 auto; padding: 40px 24px 64px; }
            header { border-bottom: 2px solid #171717; padding-bottom: 24px; margin-bottom: 28px; }
            .eyebrow { text-transform: uppercase; letter-spacing: .08em; font-size: 12px; color: #47635a; font-weight: 700; }
            h1 { font-size: clamp(32px, 6vw, 64px); line-height: 1; margin: 8px 0 16px; letter-spacing: 0; }
            h2 { font-size: 18px; margin: 0 0 12px; }
            p { line-height: 1.55; }
            .meta { display: flex; flex-wrap: wrap; gap: 10px; margin-top: 16px; }
            .meta span { border: 1px solid #999; border-radius: 999px; padding: 6px 10px; font-size: 13px; background: #fff; }
            section { margin-top: 28px; }
            .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 18px; }
            article { border: 1px solid #c9c6bd; border-radius: 8px; padding: 18px; background: #fff; }
            ul { list-style: none; padding: 0; margin: 0; display: grid; gap: 12px; }
            li { border-top: 1px solid #dad6cc; padding-top: 12px; }
            li:first-child { border-top: 0; padding-top: 0; }
            li strong, li span, li small { display: block; }
            li span { margin-top: 3px; }
            li small { color: #5f625f; margin-top: 3px; }
            footer { margin-top: 40px; color: #5f625f; font-size: 13px; }
            @media (prefers-color-scheme: dark) {
              :root { background: #151515; color: #f3f1ea; }
              header { border-color: #f3f1ea; }
              article, .meta span { background: #202020; border-color: #4a4a45; }
              li { border-color: #3a3a35; }
              li small, footer { color: #bbb6aa; }
              .eyebrow { color: #8fc0ad; }
            }
          </style>
        </head>
        <body>
          <main>
            <header>
              <p class="eyebrow">MAGI local share</p>
              <h1>\(htmlEscape(decision))</h1>
              <p>\(htmlEscape(run.question))</p>
              <div class="meta">
                <span>Run \(htmlEscape(run.id))</span>
                <span>Status \(htmlEscape(run.status.rawValue))</span>
                <span>Verdict \(htmlEscape(verdict?.kind.rawValue ?? "UNKNOWN"))</span>
                <span>Consensus \(formatScore(verdict?.consensusScore ?? 0))</span>
                <span>Confidence \(formatScore(verdict?.confidence ?? 0))</span>
              </div>
            </header>

            <section class="grid">
              <article>
                <h2>Council</h2>
                <ul>
                  \(councilHTML)
                </ul>
              </article>
              <article>
                <h2>Votes</h2>
                <ul>
                  \(votesHTML)
                </ul>
              </article>
            </section>

            <section>
              <article>
                <h2>Positions</h2>
                <ul>
                  \(positionsHTML)
                </ul>
              </article>
            </section>

            <section>
              <article>
                <h2>Evidence</h2>
                <ul>
                  \(evidenceHTML)
                </ul>
              </article>
            </section>

            \(failureHTML)

            <footer>Generated locally by MAGI. No hosted upload in v1.</footer>
          </main>
        </body>
        </html>
        """
    }

    static func jsonLine(_ object: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func formatScore(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    static func isoDate(_ date: Date) -> String {
        return DateFormatters.iso8601NoFractional.string(from: date)
    }

    static func roundTitle(_ kind: MagiRoundKind) -> String {
        switch kind {
        case .independentAnalysis:
            return "Independent analysis"
        case .crossExamination:
            return "Cross-examination"
        case .evidenceCollection:
            return "Evidence collection"
        case .revision:
            return "Revision"
        case .vote:
            return "Vote"
        case .extraDeliberation:
            return "Extra deliberation"
        }
    }

    private static func critiqueSummary(_ critique: MagiCritique) -> String {
        var parts: [String] = []
        if !critique.agreements.isEmpty {
            parts.append("\(critique.agreements.count) agreement(s)")
        }
        if !critique.disagreements.isEmpty {
            parts.append("\(critique.disagreements.count) disagreement(s)")
        }
        if !critique.missingEvidence.isEmpty {
            parts.append("\(critique.missingEvidence.count) missing evidence item(s)")
        }
        return parts.isEmpty ? "No critique details recorded." : parts.joined(separator: ", ")
    }

    private static func htmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

public enum MagiRunArtifactStore {
    public static func write(run: MagiRun, fileManager: FileManager = .default) throws -> MagiArtifactBundle {
        let bundle = run.artifactBundle ?? MagiArtifactBundle(
            runID: run.id,
            rootDirectory: MagiArtifactBundle.rootDirectory(
                runID: run.id,
                repositoryRoot: nil,
                homeDirectory: NSHomeDirectory()
            )
        )
        try fileManager.createDirectory(
            at: URL(fileURLWithPath: bundle.rootDirectory),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(run).write(to: URL(fileURLWithPath: bundle.decisionJSONPath))

        try MagiRunArtifactRenderer.decisionMarkdown(for: run).write(
            to: URL(fileURLWithPath: bundle.decisionMarkdownPath),
            atomically: true,
            encoding: .utf8
        )
        try MagiRunArtifactRenderer.transcriptJSONL(for: run).write(
            to: URL(fileURLWithPath: bundle.transcriptJSONLPath),
            atomically: true,
            encoding: .utf8
        )
        try MagiRunArtifactRenderer.graphJSON(for: run).write(
            to: URL(fileURLWithPath: bundle.graphJSONPath),
            atomically: true,
            encoding: .utf8
        )
        try MagiRunArtifactRenderer.replayJSONL(for: run).write(
            to: URL(fileURLWithPath: bundle.replayJSONLPath),
            atomically: true,
            encoding: .utf8
        )
        try MagiRunArtifactRenderer.shareHTML(for: run).write(
            to: URL(fileURLWithPath: bundle.shareHTMLPath),
            atomically: true,
            encoding: .utf8
        )

        return bundle
    }

    public static func missingRequiredPaths(
        in bundle: MagiArtifactBundle,
        fileManager: FileManager = .default
    ) -> [String] {
        bundle.requiredPaths.filter { !fileManager.fileExists(atPath: $0) }
    }

    public static func isComplete(
        _ bundle: MagiArtifactBundle,
        fileManager: FileManager = .default
    ) -> Bool {
        missingRequiredPaths(in: bundle, fileManager: fileManager).isEmpty
    }
}

public enum MagiTerminalReplayRenderer {
    public static func render(run: MagiRun?, replayJSONL: String?) -> String {
        if let run {
            return render(run: run)
        }
        return render(events: replayJSONL ?? "")
    }

    private static func render(run: MagiRun) -> String {
        var lines: [String] = [
            "MAGI Replay",
            "Run: \(run.id)",
            "Status: \(run.status.rawValue)",
            "Question: \(run.question)",
            ""
        ]

        let sortedRounds = run.rounds.sorted { $0.index < $1.index }
        let hasEvidenceCollectionRound = sortedRounds.contains { $0.kind == .evidenceCollection }
        let requestByID = Dictionary(uniqueKeysWithValues: run.evidenceRequests.map { ($0.id, $0) })
        let voteRoundID = sortedRounds.last { $0.kind == .extraDeliberation }?.id
            ?? sortedRounds.last { $0.kind == .vote }?.id

        for round in sortedRounds {
            lines.append("[Round \(round.index)] \(MagiRunArtifactRenderer.roundTitle(round.kind))")
            var eventCount = 0

            for position in run.positions.filter({ $0.roundID == round.id }) {
                lines.append("  - \(position.memberID.displayName) position: \(position.recommendation)")
                if !position.summary.isEmpty {
                    lines.append("    \(position.summary)")
                }
                eventCount += 1
            }

            for critique in run.critiques.filter({ $0.roundID == round.id }) {
                lines.append("  - \(critique.criticMemberID.displayName) critiques \(critique.targetMemberID.displayName): \(critiqueSummary(critique))")
                eventCount += 1
            }

            for request in run.evidenceRequests.filter({ $0.roundID == round.id }) {
                lines.append("  - \(request.memberID.displayName) evidence request [\(request.status.rawValue)]: \(request.reason)")
                eventCount += 1
            }

            let packetsForRound = run.evidencePackets.filter { packet in
                if round.kind == .evidenceCollection {
                    return true
                }
                guard !hasEvidenceCollectionRound else {
                    return false
                }
                if let requestID = packet.requestID, let request = requestByID[requestID] {
                    return request.roundID == round.id
                }
                return false
            }
            for packet in packetsForRound {
                lines.append("  - Evidence \(packet.collectorID): \(packet.summary)")
                eventCount += 1
            }

            if voteRoundID == round.id, let verdict = run.finalVerdict {
                for vote in verdict.votes {
                    let kind = vote.verdictKind.map { "[\($0.rawValue)] " } ?? ""
                    lines.append("  - \(vote.memberID.displayName) vote: \(kind)\(vote.choice)")
                    eventCount += 1
                }
                for veto in verdict.vetoes {
                    lines.append("  - \(veto.memberID.displayName) veto: \(veto.reason)")
                    eventCount += 1
                }
            }

            if eventCount == 0 {
                lines.append("  - No recorded events.")
            }
            lines.append("")
        }

        if sortedRounds.isEmpty {
            lines.append("[Recorded events]")
            if run.positions.isEmpty, run.evidenceRequests.isEmpty, run.evidencePackets.isEmpty, run.finalVerdict == nil {
                lines.append("  - No recorded events.")
            } else {
                for position in run.positions {
                    lines.append("  - \(position.memberID.displayName) position: \(position.recommendation)")
                }
                for request in run.evidenceRequests {
                    lines.append("  - \(request.memberID.displayName) evidence request [\(request.status.rawValue)]: \(request.reason)")
                }
                for packet in run.evidencePackets {
                    lines.append("  - Evidence \(packet.collectorID): \(packet.summary)")
                }
            }
            lines.append("")
        }

        if run.status == .failed || run.status == .interrupted {
            lines.append("Failure")
            lines.append("Status: \(run.status.rawValue)")
            lines.append("Category: \(run.metadata["failure_category"] ?? "unknown")")
            lines.append("Stage: \(run.metadata["failure_stage"] ?? run.metadata["last_checkpoint"] ?? "unknown")")
            if let error = run.metadata["error"], !error.isEmpty {
                lines.append("Error: \(error)")
            }
            lines.append("")
        }

        if let verdict = run.finalVerdict {
            lines.append("Verdict")
            lines.append("Kind: \(verdict.kind.rawValue)")
            if let decision = verdict.decision, !decision.isEmpty {
                lines.append("Decision: \(decision)")
            }
            lines.append("Consensus: \(MagiRunArtifactRenderer.formatScore(verdict.consensusScore))")
            lines.append("Confidence: \(MagiRunArtifactRenderer.formatScore(verdict.confidence))")
            if !verdict.rationale.isEmpty {
                lines.append("Rationale: \(verdict.rationale)")
            }
        } else {
            lines.append("Verdict")
            lines.append("No final verdict recorded.")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func render(events jsonl: String) -> String {
        let objects = jsonObjects(from: jsonl)
        var lines: [String] = ["MAGI Replay"]
        guard !objects.isEmpty else {
            lines.append("No replay events recorded.")
            return lines.joined(separator: "\n") + "\n"
        }

        for object in objects {
            let type = object["type"] ?? "event"
            switch type {
            case "run":
                if let runID = object["run_id"] {
                    lines.append("Run: \(runID)")
                }
                if let status = object["status"] {
                    lines.append("Status: \(status)")
                }
                if let question = object["detail"], !question.isEmpty {
                    lines.append("Question: \(question)")
                }
                lines.append("")
            case "round":
                lines.append("[\(object["title"] ?? "Round")]")
            case "position":
                let member = memberName(object["member_id"])
                let detail = object["detail"] ?? object["recommendation"] ?? ""
                lines.append("  - \(member) position: \(detail)")
            case "critique":
                let title = object["title"] ?? "\(memberName(object["critic_member_id"])) critique"
                let detail = object["detail"] ?? ""
                lines.append("  - \(title): \(detail)")
            case "evidence_request":
                let member = memberName(object["member_id"])
                let detail = object["detail"] ?? object["reason"] ?? ""
                let status = object["status"].map { " [\($0)]" } ?? ""
                lines.append("  - \(member) evidence request\(status): \(detail)")
            case "evidence":
                let collector = object["collector_id"] ?? object["title"] ?? "evidence"
                let detail = object["detail"] ?? object["summary"] ?? ""
                lines.append("  - Evidence \(collector): \(detail)")
            case "vote":
                let member = memberName(object["member_id"])
                let verdictKind = object["verdict_kind"].flatMap { $0.isEmpty ? nil : "[\($0)] " } ?? ""
                let detail = object["detail"] ?? object["choice"] ?? ""
                lines.append("  - \(member) vote: \(verdictKind)\(detail)")
            case "veto":
                let member = memberName(object["member_id"])
                let detail = object["detail"] ?? object["reason"] ?? ""
                lines.append("  - \(member) veto: \(detail)")
            case "verdict":
                lines.append("")
                lines.append("Verdict")
                if let kind = object["kind"], !kind.isEmpty {
                    lines.append("Kind: \(kind)")
                }
                if let decision = object["decision"], !decision.isEmpty {
                    lines.append("Decision: \(decision)")
                } else if let detail = object["detail"], !detail.isEmpty {
                    lines.append("Decision: \(detail)")
                }
                if let consensus = object["consensus"], !consensus.isEmpty {
                    lines.append("Consensus: \(consensus)")
                }
                if let confidence = object["confidence"], !confidence.isEmpty {
                    lines.append("Confidence: \(confidence)")
                }
            case "failure":
                lines.append("")
                lines.append("Failure")
                if let status = object["status"], !status.isEmpty {
                    lines.append("Status: \(status)")
                }
                if let category = object["category"], !category.isEmpty {
                    lines.append("Category: \(category)")
                }
                if let stage = object["stage"], !stage.isEmpty {
                    lines.append("Stage: \(stage)")
                }
                if let error = object["error"], !error.isEmpty {
                    lines.append("Error: \(error)")
                }
            default:
                if let title = object["title"], let detail = object["detail"] {
                    lines.append("  - \(title): \(detail)")
                }
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func jsonObjects(from jsonl: String) -> [[String: String]] {
        jsonl
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> [String: String]? in
                guard let data = String(line).data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    return nil
                }
                return object.reduce(into: [String: String]()) { result, pair in
                    if let value = pair.value as? String {
                        result[pair.key] = value
                    } else {
                        result[pair.key] = String(describing: pair.value)
                    }
                }
            }
    }

    private static func memberName(_ rawValue: String?) -> String {
        guard let rawValue, !rawValue.isEmpty else { return "Unknown" }
        return MagiMemberID(rawValue: rawValue)?.displayName ?? rawValue
    }

    private static func critiqueSummary(_ critique: MagiCritique) -> String {
        var parts: [String] = []
        if !critique.agreements.isEmpty {
            parts.append("\(critique.agreements.count) agreement(s)")
        }
        if !critique.disagreements.isEmpty {
            parts.append("\(critique.disagreements.count) disagreement(s)")
        }
        if !critique.missingEvidence.isEmpty {
            parts.append("\(critique.missingEvidence.count) missing evidence item(s)")
        }
        return parts.isEmpty ? "No critique details recorded." : parts.joined(separator: ", ")
    }
}
