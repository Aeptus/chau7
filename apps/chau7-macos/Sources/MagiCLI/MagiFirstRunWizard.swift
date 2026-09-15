import Chau7Core
import Darwin
import Foundation

extension MagiCLIRunner {
    func ensureConfiguredForRun() -> MagiCLIExitCode? {
        if MagiFirstRunInstaller.isConfigured(paths: paths, fileManager: fileManager) {
            do {
                _ = try MagiFirstRunInstaller.install(
                    config: loadConfig(),
                    paths: paths,
                    fileManager: fileManager,
                    overwrite: false
                )
            } catch {
                FileHandle.standardError.writeLine("MAGI configuration is invalid: \(error.localizedDescription)")
                return .usage
            }
            return nil
        }

        guard isInteractiveTerminal else {
            FileHandle.standardError.writeLine(nonInteractiveConfigMessage)
            return .usage
        }

        do {
            _ = try runFirstRunWizard()
            return nil
        } catch {
            FileHandle.standardError.writeLine("MAGI configuration failed: \(error.localizedDescription)")
            return .unavailable
        }
    }

    @discardableResult

    func runFirstRunWizard() throws -> MagiConfig {
        writeWizardTitle("First-run configuration")
        writeMuted("Reasoning defaults to max. You can edit files after setup.")
        writeStdout()

        var selections = promptSelections()
        let dryRunResults = dryRunProviders(for: selections)

        if !dryRunResults.isEmpty {
            writeStdout()
            writeStdout("Provider dry-run")
            printDryRunResults(dryRunResults)
        }

        if let plan = MagiFirstRunPlanner.fallbackPlan(selections: selections, dryRunResults: dryRunResults) {
            writeStdout()
            writeStdout("Fallback duplication")
            let affectedMembers = plan.affectedMembers.map(\.displayName).joined(separator: ", ")
            writeStdout("Members using failed providers: \(affectedMembers)")
            writeStdout("Replacement provider: \(plan.replacementProvider.rawValue)")
            if promptYesNo("Use fallback duplication now?", defaultValue: true) {
                selections = MagiFirstRunPlanner.applyingFallbackDuplication(plan, to: selections)
            }
        } else if !dryRunResults.isEmpty, dryRunResults.allSatisfy({ !$0.passed }) {
            writeStdout()
            writeStdout("No selected provider passed dry-run. MAGI will still write the requested config.")
        }

        let config = MagiFirstRunPlanner.config(from: selections)
        let result = try MagiFirstRunInstaller.install(
            config: config,
            paths: paths,
            fileManager: fileManager,
            overwrite: false
        )

        writeStdout()
        writeStdout("Created")
        if result.createdPaths.isEmpty {
            writeStdout("No new files. Existing files were left untouched.")
        } else {
            for path in result.createdPaths {
                writeStdout("- \(path)")
            }
        }

        if !result.skippedPaths.isEmpty {
            writeStdout()
            writeStdout("Existing files kept")
            for path in result.skippedPaths {
                writeStdout("- \(path)")
            }
        }

        return config
    }

    func promptSelections() -> [MagiMemberID: MagiFirstRunMemberSelection] {
        var selections = MagiFirstRunPlanner.defaultSelections()

        writeWizardSection("Setup mode")
        writeStdout("Members: \(MagiMemberID.allCases.map(\.displayName).joined(separator: ", "))")
        if promptYesNo("Use the same provider and class for all members?", defaultValue: true) {
            writeStdout()
            writeWizardSection("Shared member config")
            let provider = promptProvider(defaultValue: .codex)
            let modelClass = promptModelClass(defaultValue: .balanced)
            selections = MagiFirstRunPlanner.sharedSelections(
                provider: provider,
                modelClass: modelClass,
                reasoning: .max
            )
            writeStdout()
            writeMuted("Applied to \(MagiMemberID.allCases.map(\.displayName).joined(separator: ", ")).")
            writeStdout()
            return selections
        }

        writeStdout()
        for (index, memberID) in MagiMemberID.allCases.enumerated() {
            let current = selections[memberID] ?? MagiFirstRunMemberSelection(memberID: memberID, provider: .codex)
            writeWizardSection("Member \(index + 1) of \(MagiMemberID.allCases.count): \(memberID.displayName)")
            let provider = promptProvider(defaultValue: current.provider)
            let modelClass = promptModelClass(defaultValue: current.modelClass)
            selections[memberID] = MagiFirstRunMemberSelection(
                memberID: memberID,
                provider: provider,
                modelClass: modelClass,
                reasoning: .max
            )
            writeStdout()
        }

        return selections
    }

    func promptProvider(defaultValue: MagiProviderID) -> MagiProviderID {
        while true {
            writeChoiceLines(MagiFirstRunPromptText.providerChoiceLines(defaultValue: defaultValue))
            let value = prompt("Choose provider:")
            if value.isEmpty { return defaultValue }

            switch value.lowercased() {
            case "1", "codex":
                return .codex
            case "2", "claude":
                return .claude
            case "3", "gemini":
                return .gemini
            default:
                writeStdout("Choose codex, claude, or gemini.")
            }
        }
    }

    func promptModelClass(defaultValue: MagiModelClass) -> MagiModelClass {
        while true {
            writeChoiceLines(MagiFirstRunPromptText.modelClassChoiceLines(defaultValue: defaultValue))
            let value = prompt("Choose class:")
            if value.isEmpty { return defaultValue }

            switch value.lowercased() {
            case "1", "fast":
                return .fast
            case "2", "balanced":
                return .balanced
            case "3", "strongest":
                return .strongest
            default:
                writeStdout("Choose fast, balanced, or strongest.")
            }
        }
    }

    func promptModelName(
        defaultValue: String?,
        provider: MagiProviderID,
        modelClass: MagiModelClass
    ) -> String? {
        let defaultModel = MagiProviderCommandBuilder.resolvedModel(
            provider: provider,
            modelClass: modelClass,
            explicitModelName: nil
        )
        if let defaultValue, !defaultValue.isEmpty {
            writeMuted("Explicit model override: \(defaultValue)")
        } else {
            writeMuted("Default \(modelClass.rawValue) model for \(provider.rawValue): \(defaultModel)")
        }
        writeMuted("Press return to use the class default. Type a model id to override it.")
        let value = prompt("Model override:")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func promptYesNo(_ message: String, defaultValue: Bool) -> Bool {
        let defaultLabel = defaultValue ? "Y/n" : "y/N"
        while true {
            let value = prompt("\(message) [\(defaultLabel)]:").lowercased()
            if value.isEmpty { return defaultValue }
            if value == "y" || value == "yes" { return true }
            if value == "n" || value == "no" { return false }
            writeStdout("Choose yes or no.")
        }
    }

    func prompt(_ message: String) -> String {
        writeStdout(styled(message, .bold), terminator: " ")
        fflush(stdout)
        return readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func writeChoiceLines(_ lines: [String]) {
        for (index, line) in lines.enumerated() {
            if index == 0 {
                writeMuted(line)
            } else {
                writeStdout(line)
            }
        }
    }

    func dryRunProviders(for selections: [MagiMemberID: MagiFirstRunMemberSelection]) -> [MagiProviderDryRunResult] {
        let selectedProviders = Set(selections.values.map(\.provider))
        return MagiProviderID.allCases
            .filter { selectedProviders.contains($0) }
            .map { providerDryRunner.run(provider: $0) }
    }

}
