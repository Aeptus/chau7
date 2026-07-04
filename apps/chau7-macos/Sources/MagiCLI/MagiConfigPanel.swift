import Chau7Core
import Darwin
import Foundation

extension MagiCLIRunner {
    func runConfig() -> MagiCLIExitCode {
        printHeader()

        if MagiFirstRunInstaller.isConfigured(paths: paths, fileManager: fileManager) {
            guard isInteractiveTerminal else {
                return printConfigSummary()
            }
            return runConfigPanel()
        }

        guard isInteractiveTerminal else {
            FileHandle.standardError.writeLine(nonInteractiveConfigMessage)
            return .usage
        }

        do {
            _ = try runFirstRunWizard()
            return .success
        } catch {
            FileHandle.standardError.writeLine("MAGI configuration failed: \(error.localizedDescription)")
            return .unavailable
        }
    }

    func runConfigPanel() -> MagiCLIExitCode {
        guard isInteractiveTerminal else {
            return printConfigSummary()
        }

        guard MagiFirstRunInstaller.isConfigured(paths: paths, fileManager: fileManager) else {
            do {
                _ = try runFirstRunWizard()
                return .success
            } catch {
                FileHandle.standardError.writeLine("MAGI configuration failed: \(error.localizedDescription)")
                return .unavailable
            }
        }

        do {
            var config = try loadConfig()
            _ = try MagiFirstRunInstaller.install(
                config: config,
                paths: paths,
                fileManager: fileManager,
                overwrite: false
            )

            while true {
                printConfigPanel(config)
                let choice = prompt("Config>").lowercased()

                switch choice {
                case "", "q", "quit", "exit", "back":
                    writeMuted("Configuration panel closed.")
                    return .success
                case "1", "all":
                    writeWizardSection("Apply to all members")
                    let provider = promptProvider(defaultValue: .codex)
                    let modelClass = promptModelClass(defaultValue: .balanced)
                    let modelName = promptModelName(
                        defaultValue: nil,
                        provider: provider,
                        modelClass: modelClass
                    )
                    for memberID in MagiMemberID.allCases {
                        config.members[memberID] = MagiMemberConfiguration(
                            provider: provider.rawValue,
                            modelClass: modelClass,
                            reasoning: .max,
                            modelName: modelName
                        )
                    }
                    try saveConfig(config)
                    writeSaved()
                case "2", "member":
                    guard let memberID = promptMemberID() else { continue }
                    let current = config.members[memberID] ?? MagiMemberConfiguration(provider: "codex")
                    writeWizardSection(memberID.displayName)
                    let defaultProvider = MagiProviderID(rawValue: current.provider) ?? .codex
                    let provider = promptProvider(defaultValue: defaultProvider)
                    let modelClass = promptModelClass(defaultValue: current.modelClass)
                    let modelName = promptModelName(
                        defaultValue: current.modelName,
                        provider: provider,
                        modelClass: modelClass
                    )
                    config.members[memberID] = MagiMemberConfiguration(
                        provider: provider.rawValue,
                        modelClass: modelClass,
                        reasoning: current.reasoning,
                        modelName: modelName
                    )
                    try saveConfig(config)
                    writeSaved()
                case "3", "web":
                    config.webAccessAllowed.toggle()
                    try saveConfig(config)
                    writeSaved()
                case "4", "evidence":
                    config.evidencePolicy = promptEvidencePolicy(defaultValue: config.evidencePolicy)
                    try saveConfig(config)
                    writeSaved()
                case "5", "deadlock":
                    config.deadlockExtraRoundEnabled.toggle()
                    try saveConfig(config)
                    writeSaved()
                case "6", "veto":
                    config.vetoBlocksVerdict.toggle()
                    try saveConfig(config)
                    writeSaved()
                case "7", "tabs", "auto-close", "autoclose":
                    config.autoCloseAgentTabs.toggle()
                    try saveConfig(config)
                    writeSaved()
                case "8", "doctor":
                    writeStdout()
                    _ = runDoctor()
                case "9", "personas":
                    _ = try MagiFirstRunInstaller.install(
                        config: config,
                        paths: paths,
                        fileManager: fileManager,
                        overwrite: false
                    )
                    writeSaved("Persona and council files checked.")
                case "help", "?":
                    continue
                default:
                    writeStdout("Choose 1-9, all, member, web, evidence, deadlock, veto, tabs, doctor, personas, or quit.")
                }
            }
        } catch {
            FileHandle.standardError.writeLine("MAGI configuration failed: \(error.localizedDescription)")
            return .unavailable
        }
    }

    func printConfigPanel(_ config: MagiConfig) {
        writeStdout()
        writeWizardTitle("Configuration panel")
        writeMuted("Global: \(paths.globalConfigPath)")
        writeMuted(activeCouncilConfigLine(for: config))
        writeStdout()
        printMembers(config)
        writeStdout()
        writeStdout("Settings")
        writeStdout("- web_access_allowed: \(boolLabel(config.webAccessAllowed))")
        writeStdout("- evidence_policy: \(config.evidencePolicy.rawValue)")
        writeStdout("- deadlock_extra_round_enabled: \(boolLabel(config.deadlockExtraRoundEnabled))")
        writeStdout("- veto_blocks_verdict: \(boolLabel(config.vetoBlocksVerdict))")
        writeStdout("- auto_close_agent_tabs: \(boolLabel(config.autoCloseAgentTabs))")
        writeStdout()
        writeStdout("Actions")
        writeStdout("  1. Use one provider/class/model for all members")
        writeStdout("  2. Edit one member provider/class/model")
        writeStdout("  3. Toggle web access")
        writeStdout("  4. Change evidence policy")
        writeStdout("  5. Toggle deadlock extra round")
        writeStdout("  6. Toggle veto blocks verdict")
        writeStdout("  7. Toggle agent tab auto-close")
        writeStdout("  8. Run doctor")
        writeStdout("  9. Check/create persona/council files")
        writeMuted("Press return, q, or back to close.")
    }

    func promptMemberID() -> MagiMemberID? {
        writeChoiceLines(["Member choices"] + MagiMemberID.allCases.enumerated().map { index, memberID in
            "  \(index + 1). \(memberID.displayName)"
        })
        let value = prompt("Choose member:").lowercased()
        if value.isEmpty { return nil }

        switch value {
        case "1", "melchior":
            return .melchior
        case "2", "balthasar":
            return .balthasar
        case "3", "casper":
            return .casper
        default:
            writeStdout("Choose Melchior, Balthasar, or Casper.")
            return nil
        }
    }

    func promptEvidencePolicy(defaultValue: MagiEvidenceApprovalPolicy) -> MagiEvidenceApprovalPolicy {
        while true {
            writeChoiceLines([
                "Evidence policy choices",
                "  1. ask",
                "  2. auto_deny",
                "  3. preapproved",
                "Default: \(defaultValue.rawValue)"
            ])
            let value = prompt("Choose evidence policy:")
            if value.isEmpty { return defaultValue }

            switch value.lowercased() {
            case "1", "ask":
                return .ask
            case "2", "auto_deny", "auto-deny", "deny":
                return .autoDeny
            case "3", "preapproved", "pre-approve", "preapprove":
                return .preapproved
            default:
                writeStdout("Choose ask, auto_deny, or preapproved.")
            }
        }
    }

    func printConfigSummary() -> MagiCLIExitCode {
        do {
            let config = try loadConfig()
            _ = try MagiFirstRunInstaller.install(
                config: config,
                paths: paths,
                fileManager: fileManager,
                overwrite: false
            )

            writeStdout("Config")
            writeStdout("Global root: \(paths.globalRoot)")
            writeStdout("Global config: \(paths.globalConfigPath)")
            writeStdout(activeCouncilConfigLine(for: config))
            writeStdout("Personas: \(paths.globalPersonaDirectory)")
            writeStdout("Councils: \(paths.globalCouncilDirectory)")
            writeStdout()
            writeStdout("Status")
            writeStdout("configured")
            writeStdout()
            printMembers(config)
            printMissingPersonas(config: config)
            return .success
        } catch {
            writeStdout("Config")
            writeStdout("invalid: \(error.localizedDescription)")
            return .usage
        }
    }

}
