import Chau7Core
import Foundation

extension MagiMCPOrchestrator {
    @discardableResult
    func writeCheckpoint(
        _ run: inout MagiRun,
        stage: String,
        technicalLog: MagiTechnicalLog? = nil
    ) throws -> MagiArtifactBundle {
        MagiRunStateMachine.checkpoint(&run, stage: stage)
        if let bundle = run.artifactBundle {
            MagiRunStateMachine.recordArtifactBundle(bundle, in: &run)
        }
        technicalLog?.record(
            "checkpoint",
            stage: stage,
            fields: [
                "status": run.status.rawValue,
                "positions": String(run.positions.count),
                "critiques": String(run.critiques.count),
                "evidence_requests": String(run.evidenceRequests.count),
                "evidence_packets": String(run.evidencePackets.count)
            ]
        )

        let shouldWriteFullBundle = run.status == .completed
            || run.status == .failed
            || run.status == .interrupted
        let bundle = try writeArtifacts(run: run, fullBundle: shouldWriteFullBundle)
        if run.artifactBundle != bundle {
            MagiRunStateMachine.recordArtifactBundle(bundle, in: &run)
            return try writeArtifacts(run: run, fullBundle: shouldWriteFullBundle)
        }
        return bundle
    }

    func writeArtifacts(run: MagiRun, fullBundle: Bool) throws -> MagiArtifactBundle {
        if fullBundle {
            return try MagiRunArtifactStore.write(run: run, fileManager: fileManager)
        }
        return try MagiRunArtifactStore.writeCheckpoint(run: run, fileManager: fileManager)
    }

    func throwIfInterrupted(stage: String) throws {
        if isInterrupted() {
            throw MagiMCPOrchestratorError.interrupted(stage: stage)
        }
    }

    func failureStage(for error: Error) -> String {
        switch error {
        case let MagiMCPOrchestratorError.timedOut(stage, _, _):
            return stage
        case let MagiMCPOrchestratorError.parseFailedAfterRepair(stage, _, _):
            return stage
        case let MagiMCPOrchestratorError.interrupted(stage):
            return stage
        case MagiMCPOrchestratorError.evidenceApprovalRequiredNonInteractive:
            return "evidence approval"
        case MagiMCPOrchestratorError.mcpContractUnsupported:
            return "mcp-preflight"
        case MagiMCPOrchestratorError.launchFailed:
            return "launch"
        case let MagiMCPOrchestratorError.missingToolField(tool, _):
            return tool
        default:
            return "run"
        }
    }

    func failureCategory(for error: Error) -> MagiRunFailureCategory {
        switch error {
        case MagiMCPOrchestratorError.interrupted:
            return .interrupted
        case MagiMCPOrchestratorError.timedOut:
            return .agentTimeout
        case MagiMCPOrchestratorError.parseFailedAfterRepair:
            return .malformedJSON
        case MagiMCPOrchestratorError.evidenceApprovalRequiredNonInteractive:
            return .evidenceDenied
        case MagiMCPOrchestratorError.mcpContractUnsupported:
            return .chau7Unavailable
        case let MagiMCPOrchestratorError.launchFailed(_, reason):
            return looksLikeProviderAuthFailure(reason) ? .providerUnavailable : .tabCreationFailed
        case let MagiMCPClientError.toolError(name, message):
            if name == "agent_launch" {
                return looksLikeProviderAuthFailure(message) ? .providerUnavailable : .tabCreationFailed
            }
            return .unknown
        case MagiMCPClientError.socketMissing:
            return .mcpSocketMissing
        case MagiMCPClientError.connectFailed(_, _),
             MagiMCPClientError.readTimedOut,
             MagiMCPClientError.disconnected:
            return .chau7Unavailable
        case MagiTranscriptParseError.invalidJSON:
            return .malformedJSON
        default:
            return .unknown
        }
    }

    func looksLikeProviderAuthFailure(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return [
            "login",
            "logged in",
            "auth",
            "authenticate",
            "unauthorized",
            "permission denied",
            "api key",
            "token"
        ].contains { normalized.contains($0) }
    }

    var mcpSocketPath: String {
        "\(paths.homeDirectory)/.chau7/mcp.sock"
    }
}
