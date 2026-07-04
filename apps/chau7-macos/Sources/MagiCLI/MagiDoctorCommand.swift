import Chau7Core
import Darwin
import Foundation

extension MagiCLIRunner {
    func runDoctor() -> MagiCLIExitCode {
        printHeader()
        writeStdout("Doctor")
        writeStdout("Global config: \(paths.globalConfigPath)")
        writeStdout("Personas: \(paths.globalPersonaDirectory)")
        writeStdout("Councils: \(paths.globalCouncilDirectory)")
        let socketPath = "\(paths.homeDirectory)/.chau7/mcp.sock"
        let socketStatus = fileManager.fileExists(atPath: socketPath) ? "present" : "missing"
        writeStdout("Chau7 MCP socket: \(socketPath) (\(socketStatus))")
        printMCPCompatibility(socketPath: socketPath)
        writeStdout()

        guard MagiFirstRunInstaller.isConfigured(paths: paths, fileManager: fileManager) else {
            writeStdout("Configuration")
            writeStdout("missing")
            writeStdout()
            writeStdout("Next step")
            writeStdout("Run `magi config` from an interactive terminal.")
            return .success
        }

        do {
            let config = try loadConfig()
            writeStdout("Configuration")
            writeStdout("configured")
            writeStdout()
            printMembers(config)
            printMissingPersonas()
            printDryRunResults(for: selections(from: config))
            return .success
        } catch {
            writeStdout("Configuration")
            writeStdout("invalid: \(error.localizedDescription)")
            return .usage
        }
    }

    func printMCPCompatibility(socketPath: String) {
        writeStdout("MCP contract")
        guard fileManager.fileExists(atPath: socketPath) else {
            writeStdout("unavailable: Chau7 MCP socket is missing")
            return
        }

        let client = MagiMCPClient(socketPath: socketPath)
        do {
            try client.connectAndInitialize()
            try verifyMCPCompatibility(client: client)
            writeStdout("compatible")
        } catch {
            writeStdout("incompatible: \(error.localizedDescription)")
        }
    }

    func verifyMCPCompatibility(client: MagiMCPToolCalling) throws {
        guard let repositoryRoot = paths.repositoryRoot(fileManager: fileManager),
              !repositoryRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        do {
            _ = try client.repoEvents(MagiMCPRepoGetEventsRequest(
                repoPath: repositoryRoot,
                limit: 1,
                tabID: "tab_0",
                eventTypes: ["agent-turn-complete"],
                truncateMessages: false
            ))
        } catch let error as MagiMCPClientError {
            if case let .protocolError(message) = error,
               message.contains("unknown argument") || message.contains("Invalid params") {
                throw unsupportedMCPContractError(message)
            }
            if case let .toolError(_, message) = error {
                throw unsupportedMCPContractError(message)
            }
            throw error
        }
    }

    func unsupportedMCPContractError(_ detail: String) -> MagiMCPOrchestratorError {
        MagiMCPOrchestratorError.mcpContractUnsupported(
            message: "Chau7 MCP is too old for MAGI event-backed result capture: \(detail). Restart Chau7 from the latest build, then rerun MAGI."
        )
    }

    func printDryRunResults(for selections: [MagiMemberID: MagiFirstRunMemberSelection]) {
        let results = dryRunProviders(for: selections)
        guard !results.isEmpty else { return }

        writeStdout()
        writeStdout("Provider dry-run")
        printDryRunResults(results)
    }

    func printDryRunResults(_ results: [MagiProviderDryRunResult]) {
        for result in results {
            let status = result.passed ? "ok" : "failed"
            if result.detail.isEmpty {
                writeStdout("- \(result.provider.rawValue): \(status)")
            } else {
                writeStdout("- \(result.provider.rawValue): \(status) - \(result.detail)")
            }
        }
    }

}
