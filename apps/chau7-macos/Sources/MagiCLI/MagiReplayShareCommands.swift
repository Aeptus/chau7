import Chau7Core
import Darwin
import Foundation

extension MagiCLIRunner {
    func runReplay(runID: String) -> MagiCLIExitCode {
        let candidates = paths.artifactCandidateBundles(runID: runID, fileManager: fileManager)
        guard let bundle = candidates.first(where: { candidate in
            fileManager.fileExists(atPath: candidate.decisionJSONPath)
                || fileManager.fileExists(atPath: candidate.replayJSONLPath)
        }) else {
            FileHandle.standardError.writeLine("MAGI replay artifact not found for run \(runID).")
            FileHandle.standardError.writeLine("Checked:")
            for candidate in candidates {
                FileHandle.standardError.writeLine("- \(candidate.decisionJSONPath)")
                FileHandle.standardError.writeLine("- \(candidate.replayJSONLPath)")
            }
            return .unavailable
        }

        do {
            var run: MagiRun?
            do {
                run = try loadRunIfPresent(from: bundle.decisionJSONPath)
            } catch {
                FileHandle.standardError.writeLine("MAGI warning: decision.json is unreadable; falling back to replay.jsonl if present. \(error.localizedDescription)")
                run = nil
            }
            let replayJSONL = try loadStringIfPresent(from: bundle.replayJSONLPath)
            if run == nil, replayJSONL == nil {
                FileHandle.standardError.writeLine("MAGI replay artifact not found for run \(runID).")
                return .unavailable
            }

            printHeader()
            let output = MagiTerminalReplayRenderer.render(run: run, replayJSONL: replayJSONL)
            writeStdout(output, terminator: output.hasSuffix("\n") ? "" : "\n")
            return .success
        } catch {
            FileHandle.standardError.writeLine("MAGI could not replay run \(runID): \(error.localizedDescription)")
            return .unavailable
        }
    }

    func runShare(runID: String) -> MagiCLIExitCode {
        let candidates = paths.artifactCandidateBundles(runID: runID, fileManager: fileManager)
        if let bundle = candidates.first(where: { fileManager.fileExists(atPath: $0.decisionJSONPath) }) {
            do {
                let run = try loadRun(from: bundle.decisionJSONPath)
                try fileManager.createDirectory(
                    at: URL(fileURLWithPath: bundle.rootDirectory),
                    withIntermediateDirectories: true
                )
                try MagiRunArtifactRenderer.shareHTML(for: run).write(
                    to: URL(fileURLWithPath: bundle.shareHTMLPath),
                    atomically: true,
                    encoding: .utf8
                )

                printHeader()
                writeStdout("Share")
                writeStdout("Run id: \(runID)")
                writeStdout("Generated local share HTML: \(bundle.shareHTMLPath)")
                writeStdout("Hosted upload: disabled in v1")
                return .success
            } catch {
                if fileManager.fileExists(atPath: bundle.shareHTMLPath) {
                    FileHandle.standardError.writeLine("MAGI warning: decision.json is unreadable; using existing share.html. \(error.localizedDescription)")
                    return printExistingShare(runID: runID, bundle: bundle)
                }
                FileHandle.standardError.writeLine("MAGI could not generate share artifact: \(error.localizedDescription)")
                return .unavailable
            }
        }

        if let bundle = candidates.first(where: { fileManager.fileExists(atPath: $0.shareHTMLPath) }) {
            return printExistingShare(runID: runID, bundle: bundle)
        }

        FileHandle.standardError.writeLine("MAGI share artifact not found for run \(runID).")
        FileHandle.standardError.writeLine("Checked:")
        for candidate in candidates {
            FileHandle.standardError.writeLine("- \(candidate.decisionJSONPath)")
            FileHandle.standardError.writeLine("- \(candidate.shareHTMLPath)")
        }
        return .unavailable
    }

    func loadRunIfPresent(from path: String) throws -> MagiRun? {
        guard fileManager.fileExists(atPath: path) else { return nil }
        return try loadRun(from: path)
    }

    func loadRun(from path: String) throws -> MagiRun {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MagiRun.self, from: data)
    }

    func loadStringIfPresent(from path: String) throws -> String? {
        guard fileManager.fileExists(atPath: path) else { return nil }
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    func printExistingShare(runID: String, bundle: MagiArtifactBundle) -> MagiCLIExitCode {
        printHeader()
        writeStdout("Share")
        writeStdout("Run id: \(runID)")
        writeStdout("Existing local share HTML: \(bundle.shareHTMLPath)")
        writeStdout("Hosted upload: disabled in v1")
        return .success
    }

}
