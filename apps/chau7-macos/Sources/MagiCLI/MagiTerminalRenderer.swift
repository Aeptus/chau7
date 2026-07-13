import Chau7Core
import Darwin
import Foundation

extension MagiMCPOrchestrator {
    func announceStage(_ title: String, _ detail: String? = nil) {
        printLine("")
        printLine(terminalStyle.styled(">> \(title)", .bold, .cyan))
        if let detail {
            printLine("   \(terminalStyle.styled(detail, .dim))")
        }
    }

    func announceStep(_ detail: String) {
        printLine("   \(terminalStyle.styled(detail, .dim))")
    }

    func memberLine(
        _ member: MagiMember,
        _ detail: String,
        state: MagiMemberLineState = .info
    ) -> String {
        memberLine(member.id, displayName: member.persona.displayName, detail, state: state)
    }

    func memberLine(
        _ memberID: MagiMemberID,
        _ detail: String,
        state: MagiMemberLineState = .info
    ) -> String {
        memberLine(memberID, displayName: memberID.displayName, detail, state: state)
    }

    func memberLine(
        _ memberID: MagiMemberID,
        displayName: String,
        _ detail: String,
        state: MagiMemberLineState
    ) -> String {
        "\(memberPrefix(memberID, displayName: displayName, state: state).styled)\(detail)"
    }

    func printMemberOutput(
        _ member: MagiMember,
        _ detail: String,
        state: MagiMemberLineState
    ) {
        let prefix = memberPrefix(member.id, displayName: member.persona.displayName, state: state)
        let availableWidth = max(32, terminalStyle.wrapColumn - prefix.visibleLength)
        let lines = MagiTerminalText.wrapped(detail, width: availableWidth)
        guard let first = lines.first else {
            printLine(prefix.styled)
            return
        }

        printLine("\(prefix.styled)\(first)")
        let continuationPrefix = String(repeating: " ", count: prefix.visibleLength)
        for line in lines.dropFirst() {
            printLine("\(continuationPrefix)\(line)")
        }
    }

    func memberPrefix(
        _ memberID: MagiMemberID,
        displayName: String,
        state: MagiMemberLineState
    ) -> (styled: String, visibleLength: Int) {
        let label = terminalStyle.styled(displayName, .bold, accentStyle(for: memberID))
        let visible = "\(state.symbol) \(displayName)> "
        return ("\(state.symbol) \(label)> ", visible.count)
    }

    func collectorLine(
        _ command: MagiCollectorCommand,
        _ detail: String,
        state: MagiMemberLineState
    ) -> String {
        let label = terminalStyle.styled(command.collectorKind.rawValue, .bold, .yellow)
        return "   \(state.symbol) \(label)> \(detail)"
    }

    func statusLine(_ label: String, _ value: String) -> String {
        "\(terminalStyle.styled(label, .bold, .cyan)): \(value)"
    }

    func printWrappedStatusLine(_ label: String, _ value: String) {
        let prefix = "\(terminalStyle.styled(label, .bold, .cyan)): "
        let visiblePrefixLength = label.count + 2
        let width = max(32, terminalStyle.wrapColumn - visiblePrefixLength)
        let lines = MagiTerminalText.wrapped(value, width: width)
        guard let first = lines.first else {
            printLine(prefix)
            return
        }
        printLine("\(prefix)\(first)")
        let continuationPrefix = String(repeating: " ", count: visiblePrefixLength)
        for line in lines.dropFirst() {
            printLine("\(continuationPrefix)\(line)")
        }
    }

    func printWrappedMemberLine(
        _ memberID: MagiMemberID,
        _ detail: String,
        state: MagiMemberLineState
    ) {
        let prefix = memberPrefix(memberID, displayName: memberID.displayName, state: state)
        let width = max(32, terminalStyle.wrapColumn - prefix.visibleLength)
        let lines = MagiTerminalText.wrapped(detail, width: width)
        guard let first = lines.first else {
            printLine(prefix.styled)
            return
        }
        printLine("\(prefix.styled)\(first)")
        let continuationPrefix = String(repeating: " ", count: prefix.visibleLength)
        for line in lines.dropFirst() {
            printLine("\(continuationPrefix)\(line)")
        }
    }

    func printFinalVerdict(
        _ verdict: MagiVerdict,
        bundle: MagiArtifactBundle,
        technicalLog: MagiTechnicalLog
    ) {
        announceStage("VERDICT", "The council has resolved.")
        printLine(terminalStyle.styled(verdict.kind.rawValue, .bold, verdictStyle(for: verdict.kind)))
        printWrappedStatusLine("Kind", verdict.kind.rawValue)
        printWrappedStatusLine("Decision", verdict.decision ?? "none")
        printLine(statusLine("Confidence", String(format: "%.2f", verdict.confidence)))
        if !verdict.rationale.isEmpty {
            printWrappedStatusLine("Rationale", verdict.rationale)
        }

        if verdict.votes.isEmpty {
            printLine(statusLine("Member votes", "none"))
        } else {
            printLine(statusLine("Member votes", String(verdict.votes.count)))
            for vote in verdict.votes.sorted(by: { $0.memberID.rawValue < $1.memberID.rawValue }) {
                printWrappedMemberLine(vote.memberID, memberVoteSummary(vote), state: .done)
            }
        }

        if verdict.vetoes.isEmpty {
            printLine(statusLine("Vetoes", "none"))
        } else {
            printLine(statusLine("Vetoes", String(verdict.vetoes.count)))
            for veto in verdict.vetoes.sorted(by: { $0.memberID.rawValue < $1.memberID.rawValue }) {
                printWrappedMemberLine(veto.memberID, vetoSummary(veto), state: .repair)
            }
        }

        printLine(statusLine("Artifact path", bundle.rootDirectory))
        printLine(statusLine("Technical log", technicalLog.path))
    }

    func memberVoteSummary(_ vote: MagiVote) -> String {
        var parts: [String] = []
        if let verdictKind = vote.verdictKind {
            parts.append("verdict=\(verdictKind.rawValue)")
        }
        if let decisionID = vote.decisionID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !decisionID.isEmpty {
            parts.append("decision_id=\(decisionID)")
        }
        if !vote.choice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("choice=\(vote.choice)")
        }
        if !vote.conditions.isEmpty {
            parts.append("conditions=\(vote.conditions.joined(separator: "; "))")
        }
        parts.append("confidence=\(String(format: "%.2f", vote.confidence))")
        if !vote.rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("rationale=\(vote.rationale)")
        }
        return parts.joined(separator: " | ")
    }

    func vetoSummary(_ veto: MagiVeto) -> String {
        "veto=\(veto.reason) | scope=\(veto.scope) | blocks_verdict=\(veto.blocksVerdict)"
    }

    func questionModeSelection(
        question: String,
        override: MagiQuestionKind?
    ) -> MagiQuestionKindInference {
        if let override {
            return MagiQuestionKindInference(kind: override, reason: "explicit --mode")
        }
        return MagiQuestionKind.inferWithReason(from: question)
    }

    func modeStatusText(selection: MagiQuestionKindInference, explicit: Bool) -> String {
        if explicit {
            return "\(selection.kind.rawValue) (explicit --mode)"
        }
        return "\(selection.kind.rawValue) (inferred: \(selection.reason))"
    }

    func progressLine(
        member: MagiMember,
        stage: String,
        stageKind: MagiProtocolStage,
        pulse: Int,
        terminalCharacters: Int,
        eventCount: Int,
        mode: MagiProgressMode = .waiting
    ) -> String {
        let phrases = mode == .repair
            ? repairProgressPhrases + effectiveProcessingLines
            : effectiveProcessingLines
        let phrase = phrases[pulse % phrases.count]
        let checksum = String(format: "%04X", (pulse * 137 + terminalCharacters + eventCount) % 65535)
        let telemetry = "buf \(formatCharacterCount(terminalCharacters)) // evt \(eventCount) // chk \(checksum)"
        let detail = "\(stageKind.outputName.uppercased()) // \(phrase) // \(telemetry)"
        return memberLine(member, "\(stage): \(detail)", state: mode == .repair ? .repair : .working)
    }

    var effectiveProcessingLines: [String] {
        let configured = processingLines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return configured.isEmpty ? MagiCouncilArtFile.defaultProcessingLines : configured
    }

    func renderProgressLine(
        member: MagiMember,
        stage: String,
        stageKind: MagiProtocolStage,
        pulse: Int,
        terminalCharacters: Int,
        eventCount: Int,
        mode: MagiProgressMode = .waiting
    ) {
        let line = progressLine(
            member: member,
            stage: stage,
            stageKind: stageKind,
            pulse: pulse,
            terminalCharacters: terminalCharacters,
            eventCount: eventCount,
            mode: mode
        )
        if terminalStyle.supportsDynamicOutput {
            printRaw("\r\(terminalStyle.clearLine)\(line)")
        } else {
            printLine(line)
        }
    }

    func clearProgressLine() {
        guard terminalStyle.supportsDynamicOutput else { return }
        printRaw("\r\(terminalStyle.clearLine)")
    }

    func sleepBeforeNextPoll(
        member: MagiMember,
        stage: String,
        stageKind: MagiProtocolStage,
        pulse: inout Int,
        terminalCharacters: Int,
        eventCount: Int,
        mode: MagiProgressMode = .waiting,
        duration: TimeInterval = 3
    ) throws {
        guard terminalStyle.supportsDynamicOutput else {
            Thread.sleep(forTimeInterval: duration)
            return
        }

        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            try throwIfInterrupted(stage: stage)
            renderProgressLine(
                member: member,
                stage: stage,
                stageKind: stageKind,
                pulse: pulse,
                terminalCharacters: terminalCharacters,
                eventCount: eventCount,
                mode: mode
            )
            pulse += 1
            Thread.sleep(forTimeInterval: min(progressFrameSeconds, max(0.01, deadline.timeIntervalSinceNow)))
        }
    }

    func formatCharacterCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fm", Double(count) / 1_000_000)
        }
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000)
        }
        return String(count)
    }

    var repairProgressPhrases: [String] {
        [
            "repair requested",
            "extracting structure",
            "waiting for clean block",
            "validating contract"
        ]
    }

    func accentStyle(for memberID: MagiMemberID) -> MagiANSIStyle {
        switch memberID {
        case .melchior:
            return .cyan
        case .balthasar:
            return .magenta
        case .casper:
            return .yellow
        }
    }

    func verdictStyle(for kind: MagiVerdictKind) -> MagiANSIStyle {
        switch kind {
        case .approve, .select, .rank:
            return .green
        case .conditional, .needEvidence, .escalate:
            return .yellow
        case .reject, .deadlock, .blockedByVeto, .noConsensus:
            return .red
        }
    }

    func compact(_ value: String, limit: Int = 110) -> String {
        let trimmed = value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let index = trimmed.index(trimmed.startIndex, offsetBy: max(0, limit - 3))
        return "\(trimmed[..<index])..."
    }
}

enum MagiANSIStyle: String {
    case bold = "1"
    case dim = "2"
    case red = "31"
    case green = "32"
    case yellow = "33"
    case cyan = "36"
    case magenta = "35"
}

struct MagiRunTerminalStyle {
    var isEnabled: Bool
    var supportsDynamicOutput: Bool
    var wrapColumn: Int

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        stdoutIsTTY: Bool = isatty(STDOUT_FILENO) != 0
    ) {
        let canUseTerminalControl = stdoutIsTTY && environment["TERM"] != "dumb"
        self.isEnabled = canUseTerminalControl && environment["NO_COLOR"] == nil
        self.supportsDynamicOutput = canUseTerminalControl && environment["MAGI_NO_ANIMATION"] == nil
        self.wrapColumn = min(140, max(72, Int(environment["COLUMNS"] ?? "") ?? 110))
    }

    func styled(_ text: String, _ styles: MagiANSIStyle...) -> String {
        guard isEnabled, !styles.isEmpty else { return text }
        let prefix = styles.map(\.rawValue).joined(separator: ";")
        return "\u{001B}[\(prefix)m\(text)\u{001B}[0m"
    }

    var clearLine: String {
        "\u{001B}[2K"
    }
}

enum MagiMemberLineState {
    case info
    case working
    case ready
    case done
    case repair

    var symbol: String {
        switch self {
        case .info:
            return "-"
        case .working:
            return "~"
        case .ready:
            return "+"
        case .done:
            return "*"
        case .repair:
            return "!"
        }
    }
}

enum MagiProgressMode {
    case waiting
    case repair
}
