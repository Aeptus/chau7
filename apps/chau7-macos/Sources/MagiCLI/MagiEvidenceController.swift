import Chau7Core
import Foundation

extension MagiMCPOrchestrator {
    func reviewEvidenceRequests(
        _ requests: [MagiEvidenceRequest],
        config: MagiConfig
    ) throws -> [MagiEvidenceRequest] {
        let uniqueRequests = Array(Dictionary(grouping: requests, by: \.id).compactMap { $0.value.first })
            .sorted { $0.id < $1.id }
        guard !uniqueRequests.isEmpty else { return [] }

        announceStage(
            "PHASE 3 // FACT GATHERING",
            evidencePolicyStageDetail(config.evidencePolicy)
        )

        guard config.evidencePolicy != .ask || isInteractive else {
            throw MagiMCPOrchestratorError.evidenceApprovalRequiredNonInteractive
        }

        var reviewed: [MagiEvidenceRequest] = []
        for request in uniqueRequests {
            printLine("")
            printLine(memberLine(request.memberID, "requests a fact check", state: .working))
            printLine("   \(statusLine("Priority", request.priority.rawValue))")
            printLine("   \(statusLine("Reason", compact(request.reason)))")
            if !request.requiredEvidence.isEmpty {
                printLine("   \(statusLine("Wants", compact(request.requiredEvidence.joined(separator: "; "))))")
            }
            let commands = MagiEvidenceCollectorPlanner.commands(for: request)
            let commandReview = reviewCollectorCommands(commands, config: config)
            var reviewedRequest = request
            guard !commands.isEmpty else {
                announceStep("No collector proposed; recorded as a deliberation note.")
                reviewedRequest.status = MagiEvidencePolicyEvaluator.requestStatus(
                    commandCount: commands.count,
                    actionableCount: commandReview.actionable.count,
                    policy: config.evidencePolicy
                ) ?? .skipped
                reviewed.append(reviewedRequest)
                continue
            }

            printLine("   \(terminalStyle.styled("Proposed collectors", .bold, .cyan))")
            for command in commands {
                let payload = command.payload.map { " \($0)" } ?? ""
                let collectorNote = commandReview.skipReasons[command.id]
                    ?? (command.usesWeb ? "web" : "local")
                let collector = terminalStyle.styled(command.collectorKind.rawValue, .yellow)
                printLine("   - \(collector):\(payload) [\(collectorNote)]")
            }

            guard !commandReview.actionable.isEmpty else {
                announceStep("No runnable collector remains; recorded as skipped without approval.")
                reviewedRequest.status = MagiEvidencePolicyEvaluator.requestStatus(
                    commandCount: commands.count,
                    actionableCount: commandReview.actionable.count,
                    policy: config.evidencePolicy
                ) ?? .skipped
                reviewed.append(reviewedRequest)
                continue
            }

            switch config.evidencePolicy {
            case .ask:
                let approved = promptYesNo("Authorize this fact gathering?", defaultValue: false)
                reviewedRequest.status = MagiEvidencePolicyEvaluator.requestStatus(
                    commandCount: commands.count,
                    actionableCount: commandReview.actionable.count,
                    policy: config.evidencePolicy,
                    userApproved: approved
                ) ?? .denied
                if approved {
                    announceStep("Authorized; the fact packet enters the queue.")
                } else {
                    announceStep("Denied; the council proceeds without this packet.")
                }
            case .autoDeny:
                reviewedRequest.status = MagiEvidencePolicyEvaluator.requestStatus(
                    commandCount: commands.count,
                    actionableCount: commandReview.actionable.count,
                    policy: config.evidencePolicy
                ) ?? .denied
                announceStep("Auto-denied by evidence policy; the council proceeds without this packet.")
            case .preapproved:
                reviewedRequest.status = MagiEvidencePolicyEvaluator.requestStatus(
                    commandCount: commands.count,
                    actionableCount: commandReview.actionable.count,
                    policy: config.evidencePolicy
                ) ?? .approved
                announceStep("Preapproved by evidence policy; the fact packet enters the queue.")
            }
            reviewed.append(reviewedRequest)
        }

        return reviewed
    }

    func reviewCollectorCommands(
        _ commands: [MagiCollectorCommand],
        config: MagiConfig
    ) -> MagiCollectorCommandReview {
        MagiEvidencePolicyEvaluator.reviewCollectorCommands(
            commands,
            webAccessAllowed: config.webAccessAllowed
        )
    }

    func evidencePolicyStageDetail(_ policy: MagiEvidenceApprovalPolicy) -> String {
        switch policy {
        case .ask:
            return "The council may request external facts before the final vote. Actionable collectors require approval."
        case .autoDeny:
            return "The council may request external facts, but policy auto-denies actionable collectors."
        case .preapproved:
            return "The council may request external facts. Actionable collectors are preapproved by policy."
        }
    }

    func collectEvidence(
        for requests: [MagiEvidenceRequest],
        config: MagiConfig,
        technicalLog: MagiTechnicalLog
    ) throws -> [MagiEvidencePacket] {
        guard !requests.isEmpty else { return [] }
        announceStage("PHASE 3B // FACTS IN MOTION", "Approved collectors run, report, and disappear.")

        var packets: [MagiEvidencePacket] = []
        for request in requests {
            try throwIfInterrupted(stage: "evidence collection")
            let commands = reviewCollectorCommands(
                MagiEvidenceCollectorPlanner.commands(for: request),
                config: config
            ).actionable
            for command in commands {
                try throwIfInterrupted(stage: "evidence collection")
                printLine(collectorLine(command, "running", state: .working))
                let packet = try runCollector(command: command, request: request, technicalLog: technicalLog)
                let state: MagiMemberLineState = packet.metadata["collection_status"] == "failed" ? .repair : .done
                printLine(collectorLine(command, compact(packet.summary), state: state))
                packets.append(packet)
            }
        }
        return packets
    }

    func markEvidenceRequestsFromPackets(_ packets: [MagiEvidencePacket], in run: inout MagiRun) {
        guard !packets.isEmpty else { return }
        let statusesByRequestID = Dictionary(grouping: packets.compactMap { packet -> (String, MagiEvidenceRequestStatus)? in
            guard let requestID = packet.requestID,
                  let rawStatus = packet.metadata["collection_status"],
                  let status = MagiEvidenceRequestStatus(rawValue: rawStatus) else {
                return nil
            }
            return (requestID, status)
        }, by: { $0.0 })

        for index in run.evidenceRequests.indices {
            let requestID = run.evidenceRequests[index].id
            let statuses = statusesByRequestID[requestID]?.map(\.1) ?? []
            if statuses.contains(.failed) {
                run.evidenceRequests[index].status = .failed
            } else if statuses.contains(.fulfilled) {
                run.evidenceRequests[index].status = .fulfilled
            } else if statuses.contains(.skipped) {
                run.evidenceRequests[index].status = .skipped
            }
        }
    }

    func runCollector(
        command: MagiCollectorCommand,
        request: MagiEvidenceRequest,
        technicalLog: MagiTechnicalLog
    ) throws -> MagiEvidencePacket {
        let create = try client.createTab(MagiMCPTabCreateRequest(directory: paths.currentDirectory))
        guard let tabID = create.tabID else {
            throw MagiMCPOrchestratorError.missingToolField(tool: "tab_create", field: "tab_id")
        }
        defer {
            closeCollectorTab(tabID: tabID, collectorID: command.id, technicalLog: technicalLog)
        }

        let ready = try client.waitReady(MagiMCPTabWaitReadyRequest(tabID: tabID, timeoutMs: 30000))
        guard ready.canAcceptExec else {
            throw MagiMCPOrchestratorError.launchFailed(member: command.id, reason: "collector tab did not become ready")
        }

        let sentinel = "MAGI_COLLECTOR_DONE_\(command.id.replacingOccurrences(of: "-", with: "_"))"
        let script = """
        \(command.command)
        status=$?
        printf '\\n\(sentinel):%s\\n' "$status"
        """
        try client.exec(MagiMCPTabExecRequest(
            tabID: tabID,
            command: "/bin/sh -lc \(shellQuote(script))"
        ))

        let result = try waitForCollector(tabID: tabID, sentinel: sentinel, collectorID: command.id)
        let collectionStatus: MagiEvidenceRequestStatus = result.exitStatus == 0 ? .fulfilled : .failed
        if collectionStatus == .failed {
            technicalLog.record(
                "collector_failed",
                stage: "evidence collection",
                level: "warning",
                tabID: tabID,
                message: "Collector exited with status \(result.exitStatus)",
                fields: [
                    "collector_id": command.id,
                    "collector_kind": command.collectorKind.rawValue
                ]
            )
        }
        return MagiEvidencePacket(
            id: "\(command.id)-packet",
            requestID: request.id,
            collectorID: command.id,
            summary: collectorSummary(output: result.output, exitStatus: result.exitStatus),
            content: result.output,
            sourceDescription: command.sourceDescription,
            metadata: collectorMetadata(
                command: command,
                tabID: tabID,
                webAccessAllowed: command.usesWeb,
                collectionStatus: collectionStatus.rawValue,
                exitStatus: result.exitStatus
            )
        )
    }

    func closeCollectorTab(
        tabID: String,
        collectorID: String,
        technicalLog: MagiTechnicalLog
    ) {
        do {
            try client.closeTab(MagiMCPTabCloseRequest(tabID: tabID, force: true))
            technicalLog.record(
                "collector_tab_closed",
                stage: "evidence collection",
                tabID: tabID,
                fields: ["collector_id": collectorID]
            )
        } catch {
            technicalLog.record(
                "collector_tab_close_failed",
                stage: "evidence collection",
                level: "warning",
                tabID: tabID,
                message: error.localizedDescription,
                fields: ["collector_id": collectorID]
            )
        }
    }

    func collectorMetadata(
        command: MagiCollectorCommand,
        tabID: String?,
        webAccessAllowed: Bool,
        collectionStatus: String,
        exitStatus: Int? = nil
    ) -> [String: String] {
        var metadata: [String: String] = [
            "collector_kind": command.collectorKind.rawValue,
            "source_description": command.sourceDescription,
            "collection_status": collectionStatus,
            "requires_mcp_command_permission": String(command.requiresMCPCommandPermission),
            "approved_by_user": "true",
            "web_access": String(command.usesWeb),
            "web_access_allowed": String(webAccessAllowed)
        ]
        if let tabID {
            metadata["tab_id"] = tabID
        }
        if let exitStatus {
            metadata["exit_status"] = String(exitStatus)
        }
        if let payload = command.payload {
            switch command.collectorKind {
            case .localRepoSearch, .webQuery:
                metadata["query"] = payload
            case .localFileRead:
                metadata["path"] = payload
            case .localCommand:
                metadata["command"] = payload
            case .localGitStatus, .localGitDiff, .unsupported:
                metadata["payload"] = payload
            }
        }
        return metadata
    }

    func waitForCollector(tabID: String, sentinel: String, collectorID: String) throws -> MagiCollectorExecutionResult {
        let deadline = Date().addingTimeInterval(collectorTimeoutSeconds)
        var latest = ""
        while Date() < deadline {
            try throwIfInterrupted(stage: "evidence collection")
            latest = try tabOutput(tabID: tabID, lines: fullOutputLines)
            if let result = MagiCollectorOutputParser.parse(output: latest, sentinel: sentinel) {
                return result
            }
            Thread.sleep(forTimeInterval: min(2, max(0.01, deadline.timeIntervalSinceNow)))
        }
        throw MagiMCPOrchestratorError.timedOut(stage: "evidence collection", member: collectorID, lastError: nil)
    }

    func collectorSummary(output: String, exitStatus: Int) -> String {
        guard exitStatus == 0 else {
            let detail = firstNonEmptyLine(output).map { ": \($0)" } ?? ""
            return "collector failed with exit status \(exitStatus)\(detail)"
        }
        return firstNonEmptyLine(output) ?? "collector completed"
    }

    func firstNonEmptyLine(_ output: String) -> String? {
        output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    func promptYesNo(_ message: String, defaultValue: Bool) -> Bool {
        let suffix = defaultValue ? "Y/n" : "y/N"
        while true {
            printLine("\(message) [\(suffix)]:")
            let value = (readLine() ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if value.isEmpty { return defaultValue }
            if value == "y" || value == "yes" { return true }
            if value == "n" || value == "no" { return false }
            printLine("Choose yes or no.")
        }
    }

    func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

}
