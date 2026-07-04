import Chau7Core
import Foundation

extension MagiMCPOrchestrator {
    enum MagiTerminalReadMode {
        case none
        case tail
        case fullStable

        var logName: String {
            switch self {
            case .none:
                return "none"
            case .tail:
                return "tail"
            case .fullStable:
                return "full_stable"
            }
        }
    }

    func tabOutput(
        tabID: String,
        source: String = "pty_log",
        lines: Int? = nil,
        waitForStableMs: Int = 0
    ) throws -> String {
        let result = try client.tabOutput(MagiMCPTabOutputRequest(
            tabID: tabID,
            lines: lines ?? normalOutputTailLines,
            waitForStableMs: waitForStableMs,
            source: source
        ))
        return result.output
    }

    struct MagiPolledOutput {
        var terminalOutput: String
        var eventMessages: [String]
        var eventError: String?
        var tabStatus: MagiMCPTabStatus?
        var tabStatusError: String?
        var terminalReadMode: MagiTerminalReadMode

        var eventCharacters: Int {
            eventMessages.reduce(0) { $0 + $1.count }
        }

        var combinedOutput: String {
            let eventOutput = eventMessages
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n\n")
            if terminalOutput.isEmpty { return eventOutput }
            if eventOutput.isEmpty { return terminalOutput }
            return "\(terminalOutput)\n\n\(eventOutput)"
        }
    }

    func pollStructuredOutput(
        tabID: String,
        repositoryRoot: String?,
        sinceMillis: Int64?,
        terminalReadMode: MagiTerminalReadMode
    ) throws -> MagiPolledOutput {
        let eventCapture = try tabEventMessages(
            tabID: tabID,
            repositoryRoot: repositoryRoot,
            sinceMillis: sinceMillis
        )
        let terminalOutput: String
        switch terminalReadMode {
        case .none:
            terminalOutput = ""
        case .tail:
            terminalOutput = try tabOutput(
                tabID: tabID,
                lines: normalOutputTailLines,
                waitForStableMs: 0
            )
        case .fullStable:
            terminalOutput = try tabOutput(
                tabID: tabID,
                lines: fullOutputLines,
                waitForStableMs: 1000
            )
        }
        let statusCapture = tabStatusSnapshot(tabID: tabID)
        return MagiPolledOutput(
            terminalOutput: terminalOutput,
            eventMessages: eventCapture.messages,
            eventError: eventCapture.error,
            tabStatus: statusCapture.status,
            tabStatusError: statusCapture.error,
            terminalReadMode: terminalReadMode
        )
    }

    func tabEventMessages(
        tabID: String,
        repositoryRoot: String?,
        sinceMillis: Int64?
    ) throws -> (messages: [String], error: String?) {
        let eventTypes = [
            "agent-turn-complete",
            "finished",
            "response_complete",
            "task_finished"
        ]

        var messages: [String] = []
        var errors: [String] = []

        let runtimeCapture = try runtimeEventMessages(
            tabID: tabID,
            eventTypes: eventTypes,
            sinceMillis: sinceMillis
        )
        messages.append(contentsOf: runtimeCapture.messages)
        if let error = runtimeCapture.error {
            errors.append(error)
        }

        if messages.isEmpty {
            let repoPaths = [
                repositoryRoot,
                paths.currentDirectory
            ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            let uniqueRepoPaths = uniqueStrings(repoPaths)

            for repoPath in uniqueRepoPaths {
                let repoCapture = try repoEventMessages(
                    repoPath: repoPath,
                    tabID: tabID,
                    eventTypes: eventTypes
                )
                messages.append(contentsOf: repoCapture.messages)
                if let error = repoCapture.error {
                    errors.append(error)
                }
                if !messages.isEmpty {
                    break
                }
            }
        }

        return (uniqueStrings(messages), errors.isEmpty ? nil : errors.joined(separator: "; "))
    }

    func runtimeEventMessages(
        tabID: String,
        eventTypes: [String],
        sinceMillis: Int64?
    ) throws -> (messages: [String], error: String?) {
        let requestedTypes = Set(eventTypes.map { $0.lowercased() })
        do {
            let result = try client.runtimeEvents(MagiMCPRuntimeEventsRequest(
                limit: 200,
                sinceMillis: sinceMillis
            ))
            let messages = MagiMCPEventParsing.runtimeEventMessages(
                from: result.events,
                tabID: tabID,
                eventTypes: Array(requestedTypes)
            )
            return (messages, nil)
        } catch let error as MagiMCPClientError {
            if case let .protocolError(message) = error,
               message.contains("unknown tool") || message.contains("Unknown tool") {
                return ([], message)
            }
            if case let .toolError(_, message) = error {
                return ([], message)
            }
            throw error
        }
    }

    func repoEventMessages(
        repoPath: String,
        tabID: String,
        eventTypes: [String]
    ) throws -> (messages: [String], error: String?) {
        do {
            let result = try client.repoEvents(MagiMCPRepoGetEventsRequest(
                repoPath: repoPath,
                limit: 50,
                tabID: tabID,
                eventTypes: eventTypes,
                truncateMessages: false
            ))
            return (result.events.map(\.message), nil)
        } catch let error as MagiMCPClientError {
            if case let .protocolError(message) = error,
               message.contains("unknown argument") || message.contains("Invalid params") {
                return ([], message)
            }
            if case let .toolError(_, message) = error {
                return ([], message)
            }
            throw error
        }
    }

    func tabStatusSnapshot(tabID: String) -> (status: MagiMCPTabStatus?, error: String?) {
        do {
            let status = try client.tabStatus(MagiMCPTabStatusRequest(tabID: tabID))
            return (status, nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    func uniqueStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    struct PendingParsedMemberState {
        var session: MagiMemberTab
        var markers: MagiProtocolMarkers
        var startedAt: Date
        var eventSinceMillis: Int64
        var lastError: Error?
        var lastOutput: String = ""
        var lastCapture: MagiPolledOutput?
        var lastLoggedOutputCount: Int?
        var lastLoggedEventSignature: String?
        var lastLoggedEventError: String?
        var lastLoggedStatusError: String?
        var lastLoggedParseError: String?
        var nextProgressPulseAt: Date = Date()
        var progressPulse: Int = 0
        var nextTailPollAt: Date = Date()
    }

    func collectPendingParsed<T>(
        runID: String,
        roundID: String,
        stageKind: MagiProtocolStage,
        stage: String,
        sessions: [MagiMemberTab],
        repositoryRoot: String?,
        startedAt: Date,
        technicalLog: MagiTechnicalLog,
        recordCapture: (MagiRawTranscript) -> Void,
        parse: (MagiMemberTab, String, MagiProtocolMarkers) throws -> T,
        onParsed: (MagiMemberTab, T) throws -> Void
    ) throws -> [T] {
        let deadline = Date().addingTimeInterval(roundTimeoutSeconds)
        let eventSinceMillis = runtimeEventSinceMillis(startedAt: startedAt)
        var pendingOrder = sessions.map(\.member.id)
        var pending = Dictionary(
            uniqueKeysWithValues: sessions.map { session in
                (
                    session.member.id,
                    PendingParsedMemberState(
                        session: session,
                        markers: MagiProtocolMarkers(
                            runID: runID,
                            roundID: roundID,
                            memberID: session.member.id,
                            stage: stageKind
                        ),
                        startedAt: startedAt,
                        eventSinceMillis: eventSinceMillis
                    )
                )
            }
        )
        var results: [T] = []

        while !pendingOrder.isEmpty, Date() < deadline {
            var completedMemberIDs: [MagiMemberID] = []

            for memberID in pendingOrder {
                try throwIfInterrupted(stage: stage)
                guard var state = pending[memberID] else { continue }

                let now = Date()
                let readMode: MagiTerminalReadMode = now >= state.nextTailPollAt ? .tail : .none
                var capture = try pollStructuredOutput(
                    tabID: state.session.tabID,
                    repositoryRoot: repositoryRoot,
                    sinceMillis: state.eventSinceMillis,
                    terminalReadMode: readMode
                )
                var output = capture.combinedOutput
                if !output.isEmpty {
                    state.lastOutput = output
                }
                state.lastCapture = capture
                logStructuredPollIfNeeded(
                    state: &state,
                    capture: capture,
                    stage: stage,
                    stageKind: stageKind,
                    technicalLog: technicalLog
                )
                renderPendingProgressIfNeeded(
                    state: &state,
                    capture: capture,
                    stage: stage,
                    stageKind: stageKind
                )

                do {
                    let parsed = try parse(state.session, output, state.markers)
                    try completePendingParse(
                        parsed,
                        state: state,
                        output: output,
                        roundID: roundID,
                        stageKind: stageKind,
                        stage: stage,
                        technicalLog: technicalLog,
                        recordCapture: recordCapture,
                        onParsed: onParsed
                    )
                    results.append(parsed)
                    completedMemberIDs.append(memberID)
                    continue
                } catch {
                    state.lastError = error
                    logStructuredParsePendingIfNeeded(
                        state: &state,
                        error: error,
                        stage: stage,
                        stageKind: stageKind,
                        technicalLog: technicalLog
                    )
                }

                if shouldFetchFullOutputForParse(
                    state.lastError,
                    capture: capture,
                    output: output,
                    markers: state.markers,
                    elapsed: Date().timeIntervalSince(state.startedAt)
                ) {
                    capture = try pollStructuredOutput(
                        tabID: state.session.tabID,
                        repositoryRoot: repositoryRoot,
                        sinceMillis: state.eventSinceMillis,
                        terminalReadMode: .fullStable
                    )
                    output = capture.combinedOutput
                    state.lastOutput = output
                    state.lastCapture = capture
                    logStructuredPollIfNeeded(
                        state: &state,
                        capture: capture,
                        stage: stage,
                        stageKind: stageKind,
                        technicalLog: technicalLog
                    )

                    do {
                        let parsed = try parse(state.session, output, state.markers)
                        try completePendingParse(
                            parsed,
                            state: state,
                            output: output,
                            roundID: roundID,
                            stageKind: stageKind,
                            stage: stage,
                            technicalLog: technicalLog,
                            recordCapture: recordCapture,
                            onParsed: onParsed
                        )
                        results.append(parsed)
                        completedMemberIDs.append(memberID)
                        continue
                    } catch {
                        state.lastError = error
                        logStructuredParsePendingIfNeeded(
                            state: &state,
                            error: error,
                            stage: stage,
                            stageKind: stageKind,
                            technicalLog: technicalLog
                        )
                    }
                }

                if shouldRunStableRepair(
                    state.lastError,
                    capture: capture,
                    output: state.lastOutput,
                    markers: state.markers,
                    elapsed: Date().timeIntervalSince(state.startedAt)
                ) {
                    let parseError = state.lastError?.localizedDescription ?? "structured block did not parse after stable output"
                    recordCapture(rawTranscript(
                        memberID: state.session.member.id,
                        roundID: roundID,
                        stage: stageKind.rawValue,
                        tabID: state.session.tabID,
                        output: state.lastOutput,
                        parseError: parseError,
                        repairAttempted: true,
                        repairSucceeded: false
                    ))
                    let parsed = try runStructuredRepair(
                        context: StructuredRepairContext(
                            runID: runID,
                            roundID: roundID,
                            stageKind: stageKind,
                            stage: stage,
                            member: state.session.member,
                            tabID: state.session.tabID,
                            repositoryRoot: repositoryRoot,
                            expectedMarkers: state.markers,
                            parseError: parseError,
                            lastOutput: state.lastOutput,
                            lastError: state.lastError
                        ),
                        technicalLog: technicalLog,
                        recordCapture: recordCapture
                    ) { output in
                        try parse(state.session, output, state.markers)
                    }
                    try onParsed(state.session, parsed)
                    results.append(parsed)
                    completedMemberIDs.append(memberID)
                    continue
                }

                if readMode == .tail {
                    state.nextTailPollAt = Date().addingTimeInterval(normalTailPollIntervalSeconds)
                }
                pending[memberID] = state
            }

            if !completedMemberIDs.isEmpty {
                for memberID in completedMemberIDs {
                    pending.removeValue(forKey: memberID)
                }
                pendingOrder.removeAll { completedMemberIDs.contains($0) }
            }

            if !pendingOrder.isEmpty {
                Thread.sleep(forTimeInterval: terminalStyle.supportsDynamicOutput ? 0.25 : 0.75)
            }
        }

        guard pendingOrder.isEmpty else {
            let timedOutID = pendingOrder[0]
            guard var state = pending[timedOutID] else {
                throw MagiMCPOrchestratorError.timedOut(stage: stage, member: "unknown", lastError: nil)
            }
            return try handlePendingTimeout(
                state: &state,
                results: results,
                runID: runID,
                roundID: roundID,
                stageKind: stageKind,
                stage: stage,
                repositoryRoot: repositoryRoot,
                technicalLog: technicalLog,
                recordCapture: recordCapture,
                parse: parse,
                onParsed: onParsed
            )
        }

        clearProgressLine()
        return results
    }

    func completePendingParse<T>(
        _ parsed: T,
        state: PendingParsedMemberState,
        output: String,
        roundID: String,
        stageKind: MagiProtocolStage,
        stage: String,
        technicalLog: MagiTechnicalLog,
        recordCapture: (MagiRawTranscript) -> Void,
        onParsed: (MagiMemberTab, T) throws -> Void
    ) throws {
        technicalLog.record(
            "structured_parse_succeeded",
            stage: stage,
            memberID: state.session.member.id,
            tabID: state.session.tabID,
            fields: [
                "stage_kind": stageKind.rawValue,
                "source": state.lastCapture?.terminalReadMode.logName ?? "unknown"
            ]
        )
        recordCapture(rawTranscript(
            memberID: state.session.member.id,
            roundID: roundID,
            stage: stageKind.rawValue,
            tabID: state.session.tabID,
            output: output
        ))
        clearProgressLine()
        try onParsed(state.session, parsed)
    }

    func handlePendingTimeout<T>(
        state: inout PendingParsedMemberState,
        results: [T],
        runID: String,
        roundID: String,
        stageKind: MagiProtocolStage,
        stage: String,
        repositoryRoot: String?,
        technicalLog: MagiTechnicalLog,
        recordCapture: (MagiRawTranscript) -> Void,
        parse: (MagiMemberTab, String, MagiProtocolMarkers) throws -> T,
        onParsed: (MagiMemberTab, T) throws -> Void
    ) throws -> [T] {
        clearProgressLine()
        let capture = try pollStructuredOutput(
            tabID: state.session.tabID,
            repositoryRoot: repositoryRoot,
            sinceMillis: state.eventSinceMillis,
            terminalReadMode: .fullStable
        )
        let output = capture.combinedOutput
        state.lastOutput = output
        state.lastCapture = capture

        do {
            let parsed = try parse(state.session, output, state.markers)
            try completePendingParse(
                parsed,
                state: state,
                output: output,
                roundID: roundID,
                stageKind: stageKind,
                stage: stage,
                technicalLog: technicalLog,
                recordCapture: recordCapture,
                onParsed: onParsed
            )
            return results + [parsed]
        } catch {
            state.lastError = error
        }

        let parseError = state.lastError?.localizedDescription ?? "structured block did not appear before timeout"
        if shouldRunStableRepair(
            state.lastError,
            capture: capture,
            output: output,
            markers: state.markers,
            elapsed: Date().timeIntervalSince(state.startedAt)
        ) {
            recordCapture(rawTranscript(
                memberID: state.session.member.id,
                roundID: roundID,
                stage: stageKind.rawValue,
                tabID: state.session.tabID,
                output: output,
                parseError: parseError,
                repairAttempted: true,
                repairSucceeded: false
            ))
            let parsed = try runStructuredRepair(
                context: StructuredRepairContext(
                    runID: runID,
                    roundID: roundID,
                    stageKind: stageKind,
                    stage: stage,
                    member: state.session.member,
                    tabID: state.session.tabID,
                    repositoryRoot: repositoryRoot,
                    expectedMarkers: state.markers,
                    parseError: parseError,
                    lastOutput: output,
                    lastError: state.lastError
                ),
                technicalLog: technicalLog,
                recordCapture: recordCapture
            ) { repairOutput in
                try parse(state.session, repairOutput, state.markers)
            }
            try onParsed(state.session, parsed)
            return results + [parsed]
        }

        recordCapture(rawTranscript(
            memberID: state.session.member.id,
            roundID: roundID,
            stage: stageKind.rawValue,
            tabID: state.session.tabID,
            output: output,
            parseError: parseError,
            repairAttempted: false,
            repairSucceeded: false
        ))
        technicalLog.record(
            "structured_parse_timed_out",
            stage: stage,
            level: "error",
            memberID: state.session.member.id,
            tabID: state.session.tabID,
            message: parseError,
            fields: ["stage_kind": stageKind.rawValue]
        )
        throw MagiMCPOrchestratorError.timedOut(
            stage: stage,
            member: state.session.member.persona.displayName,
            lastError: parseError
        )
    }

    func logStructuredPollIfNeeded(
        state: inout PendingParsedMemberState,
        capture: MagiPolledOutput,
        stage: String,
        stageKind: MagiProtocolStage,
        technicalLog: MagiTechnicalLog
    ) {
        if capture.terminalReadMode != .none, state.lastLoggedOutputCount != capture.terminalOutput.count {
            state.lastLoggedOutputCount = capture.terminalOutput.count
            technicalLog.record(
                "tab_output_polled",
                stage: stage,
                memberID: state.session.member.id,
                tabID: state.session.tabID,
                fields: [
                    "characters": String(capture.terminalOutput.count),
                    "lines": capture.terminalReadMode == .fullStable ? String(fullOutputLines) : String(normalOutputTailLines),
                    "mode": capture.terminalReadMode.logName,
                    "stage_kind": stageKind.rawValue
                ]
            )
        }

        let eventSignature = "\(capture.eventMessages.count):\(capture.eventCharacters)"
        if capture.eventMessages.isEmpty == false, state.lastLoggedEventSignature != eventSignature {
            state.lastLoggedEventSignature = eventSignature
            technicalLog.record(
                "repo_events_polled",
                stage: stage,
                memberID: state.session.member.id,
                tabID: state.session.tabID,
                fields: [
                    "events": String(capture.eventMessages.count),
                    "characters": String(capture.eventCharacters),
                    "since_millis": String(state.eventSinceMillis),
                    "stage_kind": stageKind.rawValue
                ]
            )
        }
        if let eventError = capture.eventError, state.lastLoggedEventError != eventError {
            state.lastLoggedEventError = eventError
            technicalLog.record(
                "repo_events_unavailable",
                stage: stage,
                level: "warning",
                memberID: state.session.member.id,
                tabID: state.session.tabID,
                message: eventError
            )
        }
        if let statusError = capture.tabStatusError, state.lastLoggedStatusError != statusError {
            state.lastLoggedStatusError = statusError
            technicalLog.record(
                "tab_status_unavailable",
                stage: stage,
                level: "warning",
                memberID: state.session.member.id,
                tabID: state.session.tabID,
                message: statusError
            )
        }
    }

    func logStructuredParsePendingIfNeeded(
        state: inout PendingParsedMemberState,
        error: Error,
        stage: String,
        stageKind: MagiProtocolStage,
        technicalLog: MagiTechnicalLog
    ) {
        let message = error.localizedDescription
        guard state.lastLoggedParseError != message else { return }
        state.lastLoggedParseError = message
        technicalLog.record(
            "structured_parse_pending",
            stage: stage,
            memberID: state.session.member.id,
            tabID: state.session.tabID,
            message: message,
            fields: ["stage_kind": stageKind.rawValue]
        )
    }

    func renderPendingProgressIfNeeded(
        state: inout PendingParsedMemberState,
        capture: MagiPolledOutput,
        stage: String,
        stageKind: MagiProtocolStage,
        mode: MagiProgressMode = .waiting
    ) {
        let now = Date()
        if terminalStyle.supportsDynamicOutput || progressPulseSeconds <= 0 || now >= state.nextProgressPulseAt {
            renderProgressLine(
                member: state.session.member,
                stage: stage,
                stageKind: stageKind,
                pulse: state.progressPulse,
                terminalCharacters: capture.terminalOutput.count,
                eventCount: capture.eventMessages.count,
                mode: mode
            )
            state.progressPulse += 1
            state.nextProgressPulseAt = now.addingTimeInterval(progressPulseSeconds)
        }
    }

    func shouldFetchFullOutputForParse(
        _ error: Error?,
        capture: MagiPolledOutput,
        output: String,
        markers: MagiProtocolMarkers,
        elapsed: TimeInterval
    ) -> Bool {
        guard capture.terminalReadMode != .fullStable else { return false }
        guard error != nil else { return false }
        if !MagiTranscriptParser.blockCandidates(in: output, markers: markers).isEmpty {
            return true
        }
        let hasMarkerText = output.contains(markers.begin) || output.contains(markers.end)
        guard hasMarkerText || elapsed >= idleRepairGraceSeconds else { return false }
        guard elapsed >= idleRepairGraceSeconds else { return false }
        return capture.tabStatus.map(MagiMCPEventParsing.tabStatusIsIdleForRepair) ?? false
    }

    func shouldRunStableRepair(
        _ error: Error?,
        capture: MagiPolledOutput,
        output: String,
        markers: MagiProtocolMarkers? = nil,
        elapsed: TimeInterval
    ) -> Bool {
        guard error != nil else { return false }
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard elapsed >= idleRepairGraceSeconds else { return false }
        if let markers, shouldTreatAsEchoedPromptMarkers(output, markers: markers) {
            return false
        }
        return capture.tabStatus.map(MagiMCPEventParsing.tabStatusIsIdleForRepair) ?? false
    }

    func shouldTreatAsEchoedPromptMarkers(_ output: String, markers: MagiProtocolMarkers) -> Bool {
        guard MagiTranscriptParser.blockCandidates(in: output, markers: markers).isEmpty else {
            return false
        }
        let markerLines = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.contains(markers.begin) || $0.contains(markers.end) }
        guard !markerLines.isEmpty else { return false }
        return markerLines.allSatisfy { $0 != markers.begin && $0 != markers.end }
    }

    func runtimeEventSinceMillis(startedAt: Date) -> Int64 {
        Int64(max(0, (startedAt.timeIntervalSince1970 - 2) * 1000))
    }

    func waitForParsed<T>(
        runID: String,
        roundID: String,
        stageKind: MagiProtocolStage,
        stage: String,
        member: MagiMember,
        tabID: String,
        repositoryRoot: String?,
        technicalLog: MagiTechnicalLog,
        recordCapture: (MagiRawTranscript) -> Void,
        parser: (String) throws -> T
    ) throws -> T {
        let deadline = Date().addingTimeInterval(roundTimeoutSeconds)
        let startedAt = Date()
        let expectedMarkers = MagiProtocolMarkers(
            runID: runID,
            roundID: roundID,
            memberID: member.id,
            stage: stageKind
        )
        var lastError: Error?
        var lastOutput = ""
        var lastLoggedOutputCount: Int?
        var lastLoggedEventSignature: String?
        var lastLoggedEventError: String?
        var lastLoggedStatusError: String?
        var nextProgressPulseAt = Date()
        var progressPulse = 0

        while Date() < deadline {
            try throwIfInterrupted(stage: stage)
            let capture = try pollStructuredOutput(
                tabID: tabID,
                repositoryRoot: repositoryRoot,
                sinceMillis: runtimeEventSinceMillis(startedAt: startedAt),
                terminalReadMode: .tail
            )
            let output = capture.combinedOutput
            lastOutput = output
            let now = Date()
            if terminalStyle.supportsDynamicOutput {
                renderProgressLine(
                    member: member,
                    stage: stage,
                    stageKind: stageKind,
                    pulse: progressPulse,
                    terminalCharacters: capture.terminalOutput.count,
                    eventCount: capture.eventMessages.count
                )
                progressPulse += 1
            } else if progressPulseSeconds > 0, now >= nextProgressPulseAt {
                renderProgressLine(
                    member: member,
                    stage: stage,
                    stageKind: stageKind,
                    pulse: progressPulse,
                    terminalCharacters: capture.terminalOutput.count,
                    eventCount: capture.eventMessages.count
                )
                progressPulse += 1
                nextProgressPulseAt = now.addingTimeInterval(progressPulseSeconds)
            }
            if lastLoggedOutputCount != capture.terminalOutput.count {
                lastLoggedOutputCount = capture.terminalOutput.count
                technicalLog.record(
                    "tab_output_polled",
                    stage: stage,
                    memberID: member.id,
                    tabID: tabID,
                    fields: ["characters": String(capture.terminalOutput.count)]
                )
            }
            let eventSignature = "\(capture.eventMessages.count):\(capture.eventCharacters)"
            if capture.eventMessages.isEmpty == false, lastLoggedEventSignature != eventSignature {
                lastLoggedEventSignature = eventSignature
                technicalLog.record(
                    "repo_events_polled",
                    stage: stage,
                    memberID: member.id,
                    tabID: tabID,
                    fields: [
                        "events": String(capture.eventMessages.count),
                        "characters": String(capture.eventCharacters)
                    ]
                )
            }
            if let eventError = capture.eventError, lastLoggedEventError != eventError {
                lastLoggedEventError = eventError
                technicalLog.record(
                    "repo_events_unavailable",
                    stage: stage,
                    level: "warning",
                    memberID: member.id,
                    tabID: tabID,
                    message: eventError
                )
            }
            if let statusError = capture.tabStatusError, lastLoggedStatusError != statusError {
                lastLoggedStatusError = statusError
                technicalLog.record(
                    "tab_status_unavailable",
                    stage: stage,
                    level: "warning",
                    memberID: member.id,
                    tabID: tabID,
                    message: statusError
                )
            }
            do {
                let parsed = try parser(output)
                technicalLog.record(
                    "structured_parse_succeeded",
                    stage: stage,
                    memberID: member.id,
                    tabID: tabID,
                    fields: ["stage_kind": stageKind.rawValue]
                )
                recordCapture(rawTranscript(
                    memberID: member.id,
                    roundID: roundID,
                    stage: stageKind.rawValue,
                    tabID: tabID,
                    output: output
                ))
                clearProgressLine()
                return parsed
            } catch {
                lastError = error
                technicalLog.record(
                    "structured_parse_pending",
                    stage: stage,
                    memberID: member.id,
                    tabID: tabID,
                    message: error.localizedDescription,
                    fields: ["stage_kind": stageKind.rawValue]
                )
                if shouldRepairImmediately(error) {
                    break
                }
                if shouldRepairAfterIdleMissingBlock(
                    error,
                    capture: capture,
                    output: output,
                    markers: expectedMarkers,
                    elapsed: Date().timeIntervalSince(startedAt)
                ) {
                    technicalLog.record(
                        "structured_parse_idle_without_block",
                        stage: stage,
                        memberID: member.id,
                        tabID: tabID,
                        message: error.localizedDescription,
                        fields: ["stage_kind": stageKind.rawValue]
                    )
                    break
                }
                try sleepBeforeNextPoll(
                    member: member,
                    stage: stage,
                    stageKind: stageKind,
                    pulse: &progressPulse,
                    terminalCharacters: capture.terminalOutput.count,
                    eventCount: capture.eventMessages.count
                )
            }
        }

        clearProgressLine()

        let parseError = lastError?.localizedDescription ?? "structured block did not appear before timeout"
        recordCapture(rawTranscript(
            memberID: member.id,
            roundID: roundID,
            stage: stageKind.rawValue,
            tabID: tabID,
            output: lastOutput,
            parseError: parseError,
            repairAttempted: true,
            repairSucceeded: false
        ))

        return try runStructuredRepair(
            context: StructuredRepairContext(
                runID: runID,
                roundID: roundID,
                stageKind: stageKind,
                stage: stage,
                member: member,
                tabID: tabID,
                repositoryRoot: repositoryRoot,
                expectedMarkers: expectedMarkers,
                parseError: parseError,
                lastOutput: lastOutput,
                lastError: lastError
            ),
            technicalLog: technicalLog,
            recordCapture: recordCapture,
            parser: parser
        )
    }

    /// Inputs the repair sub-flow needs from the wait loop that spawned it.
    struct StructuredRepairContext {
        let runID: String
        let roundID: String
        let stageKind: MagiProtocolStage
        let stage: String
        let member: MagiMember
        let tabID: String
        let repositoryRoot: String?
        let expectedMarkers: MagiProtocolMarkers
        let parseError: String
        let lastOutput: String
        let lastError: Error?
    }

    /// The structured-output repair sub-flow of `waitForParsed`: sends the
    /// repair prompt, polls until the re-emitted block parses, and records
    /// the terminal outcome. Split out so the poll loop and the repair flow
    /// each stay within readable (and lintable) bounds.

    func runStructuredRepair<T>(
        context: StructuredRepairContext,
        technicalLog: MagiTechnicalLog,
        recordCapture: (MagiRawTranscript) -> Void,
        parser: (String) throws -> T
    ) throws -> T {
        let runID = context.runID
        let roundID = context.roundID
        let stageKind = context.stageKind
        let stage = context.stage
        let member = context.member
        let tabID = context.tabID
        let repositoryRoot = context.repositoryRoot
        let expectedMarkers = context.expectedMarkers
        let parseError = context.parseError
        let lastOutput = context.lastOutput
        let lastError = context.lastError
        clearProgressLine()
        defer { clearProgressLine() }
        printLine(memberLine(member, "requesting structured output repair", state: .repair))
        technicalLog.record(
            "structured_repair_requested",
            stage: stage,
            memberID: member.id,
            tabID: tabID,
            message: parseError,
            fields: ["stage_kind": stageKind.rawValue]
        )
        let repairTranscript = MagiPromptBuilder.repairTranscriptExcerpt(
            lastOutput,
            markers: expectedMarkers,
            maxCharacters: repairTranscriptMaxCharacters
        )
        technicalLog.record(
            "structured_repair_transcript_excerpt",
            stage: stage,
            memberID: member.id,
            tabID: tabID,
            fields: [
                "raw_characters": String(lastOutput.count),
                "excerpt_characters": String(repairTranscript.count)
            ]
        )
        let repairPrompt = MagiPromptBuilder.repairPrompt(
            runID: runID,
            roundID: roundID,
            member: member,
            stage: stageKind,
            parseError: parseError,
            rawTranscript: repairTranscript
        )
        try sendPrompt(
            repairPrompt,
            to: tabID,
            stage: "\(stage) repair",
            memberID: member.id,
            technicalLog: technicalLog
        )

        let repairDeadline = Date().addingTimeInterval(repairTimeoutSeconds)
        var repairOutput = ""
        var repairError: Error?
        var nextRepairProgressPulseAt = Date()
        var repairPulse = 0

        while Date() < repairDeadline {
            try throwIfInterrupted(stage: "\(stage) repair")
            let repairCapture = try pollStructuredOutput(
                tabID: tabID,
                repositoryRoot: repositoryRoot,
                sinceMillis: nil,
                terminalReadMode: .fullStable
            )
            repairOutput = repairCapture.combinedOutput
            let now = Date()
            if terminalStyle.supportsDynamicOutput {
                renderProgressLine(
                    member: member,
                    stage: "\(stage) repair",
                    stageKind: stageKind,
                    pulse: repairPulse,
                    terminalCharacters: repairCapture.terminalOutput.count,
                    eventCount: repairCapture.eventMessages.count,
                    mode: .repair
                )
                repairPulse += 1
            } else if progressPulseSeconds > 0, now >= nextRepairProgressPulseAt {
                renderProgressLine(
                    member: member,
                    stage: "\(stage) repair",
                    stageKind: stageKind,
                    pulse: repairPulse,
                    terminalCharacters: repairCapture.terminalOutput.count,
                    eventCount: repairCapture.eventMessages.count,
                    mode: .repair
                )
                repairPulse += 1
                nextRepairProgressPulseAt = now.addingTimeInterval(progressPulseSeconds)
            }
            do {
                let parsed = try parser(repairOutput)
                technicalLog.record(
                    "structured_repair_succeeded",
                    stage: stage,
                    memberID: member.id,
                    tabID: tabID,
                    fields: ["stage_kind": stageKind.rawValue]
                )
                recordCapture(rawTranscript(
                    memberID: member.id,
                    roundID: roundID,
                    stage: stageKind.rawValue,
                    tabID: tabID,
                    output: repairOutput,
                    repairAttempted: true,
                    repairSucceeded: true
                ))
                return parsed
            } catch {
                repairError = error
                technicalLog.record(
                    "structured_repair_pending",
                    stage: stage,
                    memberID: member.id,
                    tabID: tabID,
                    message: error.localizedDescription,
                    fields: ["stage_kind": stageKind.rawValue]
                )
                try sleepBeforeNextPoll(
                    member: member,
                    stage: "\(stage) repair",
                    stageKind: stageKind,
                    pulse: &repairPulse,
                    terminalCharacters: repairCapture.terminalOutput.count,
                    eventCount: repairCapture.eventMessages.count,
                    mode: .repair
                )
            }
        }

        recordCapture(rawTranscript(
            memberID: member.id,
            roundID: roundID,
            stage: stageKind.rawValue,
            tabID: tabID,
            output: repairOutput,
            parseError: repairError?.localizedDescription,
            repairAttempted: true,
            repairSucceeded: false
        ))

        if lastError == nil {
            technicalLog.record(
                "structured_parse_timed_out",
                stage: stage,
                level: "error",
                memberID: member.id,
                tabID: tabID,
                message: repairError?.localizedDescription,
                fields: ["stage_kind": stageKind.rawValue]
            )
            throw MagiMCPOrchestratorError.timedOut(
                stage: stage,
                member: member.persona.displayName,
                lastError: repairError?.localizedDescription
            )
        }

        technicalLog.record(
            "structured_parse_failed",
            stage: stage,
            level: "error",
            memberID: member.id,
            tabID: tabID,
            message: repairError?.localizedDescription ?? lastError?.localizedDescription,
            fields: ["stage_kind": stageKind.rawValue]
        )
        throw MagiMCPOrchestratorError.parseFailedAfterRepair(
            stage: stage,
            member: member.persona.displayName,
            lastError: repairError?.localizedDescription ?? lastError?.localizedDescription
        )
    }

    func shouldRepairImmediately(_ error: Error) -> Bool {
        _ = error
        return false
    }

    func shouldRepairAfterIdleMissingBlock(
        _ error: Error,
        capture: MagiPolledOutput,
        output: String,
        markers: MagiProtocolMarkers,
        elapsed: TimeInterval
    ) -> Bool {
        guard case .missingBlock = error as? MagiTranscriptParseError else {
            return false
        }
        _ = markers
        guard elapsed >= idleRepairGraceSeconds else { return false }
        return capture.tabStatus.map(MagiMCPEventParsing.tabStatusIsIdleForRepair) ?? false
    }

    func rawTranscript(
        memberID: MagiMemberID,
        roundID: String,
        stage: String,
        tabID: String,
        output: String,
        parseError: String? = nil,
        repairAttempted: Bool = false,
        repairSucceeded: Bool = false
    ) -> MagiRawTranscript {
        MagiRawTranscript(
            id: "\(roundID)-\(memberID.rawValue)-\(stage)-raw-\(UUID().uuidString.lowercased())",
            memberID: memberID,
            roundID: roundID,
            stage: stage,
            tabID: tabID,
            output: output,
            parseError: parseError,
            repairAttempted: repairAttempted,
            repairSucceeded: repairSucceeded
        )
    }

}
