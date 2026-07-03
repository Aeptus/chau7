import Foundation
import os.log

/// Resolves (and, in development, rebuilds) the chau7-remote agent binary.
/// Extracted verbatim from RemoteControlManager, which previously embedded
/// this ~200-line resolution chain: refresh-from-Go-source when the checkout
/// is newer, dev build outputs, the installed App Support copy, the bundled
/// resource (synced into App Support), and a last-resort `go build`.
///
/// Failure detail surfaces through `lastError` so the owning manager can
/// propagate it into its own user-visible error state, exactly as the
/// embedded code did.
@MainActor
final class RemoteAgentBinaryProvider {
    private let logger: Logger
    /// Supplies the App Support data directory (owned by the manager, which
    /// also derives the IPC socket path from it). `nil` when unavailable.
    private let dataDirectory: () -> URL?

    /// Human-readable detail from the most recent failed build/resolution
    /// step, mirroring the manager's historical `lastError` writes.
    private(set) var lastError: String?

    init(logger: Logger, dataDirectory: @escaping () -> URL?) {
        self.logger = logger
        self.dataDirectory = dataDirectory
    }

    func resolveBinary() -> URL? {
        let fileManager = FileManager.default

        if let sourceURL = remoteAgentSourceURL(),
           let installedPath = installedRemoteBinaryPath(),
           shouldRefreshInstalledRemoteBinary(at: installedPath, from: sourceURL) {
            if buildRemoteAgent(from: sourceURL, outputURL: installedPath),
               FileManager.default.isExecutableFile(atPath: installedPath.path) {
                return installedPath
            }
        }

        if let devPath = devRemoteBinaryPath(),
           fileManager.isExecutableFile(atPath: devPath.path) {
            return devPath
        }

        if let installedPath = installedRemoteBinaryPath(),
           fileManager.isExecutableFile(atPath: installedPath.path) {
            return installedPath
        }

        if let bundlePath = bundledRemoteBinaryPath(),
           fileManager.isExecutableFile(atPath: bundlePath.path) {
            syncInstalledRemoteBinary(from: bundlePath)
            if let installedPath = installedRemoteBinaryPath(),
               fileManager.isExecutableFile(atPath: installedPath.path) {
                return installedPath
            }
            return bundlePath
        }

        if let sourceURL = remoteAgentSourceURL(),
           let installedPath = installedRemoteBinaryPath(),
           buildRemoteAgent(from: sourceURL, outputURL: installedPath),
           fileManager.isExecutableFile(atPath: installedPath.path) {
            return installedPath
        }

        return nil
    }

    private func syncInstalledRemoteBinary(from bundledPath: URL) {
        guard let installedPath = installedRemoteBinaryPath() else { return }
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: installedPath.path),
           !shouldReplaceInstalledRemoteBinary(at: installedPath, with: bundledPath) {
            return
        }

        do {
            try fileManager.createDirectory(
                at: installedPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: installedPath.path) {
                try fileManager.removeItem(at: installedPath)
            }
            try fileManager.copyItem(at: bundledPath, to: installedPath)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedPath.path)
        } catch {
            logger.warning("Failed to sync bundled remote agent to App Support: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func shouldReplaceInstalledRemoteBinary(at installedPath: URL, with bundledPath: URL) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: installedPath.path) else { return true }
        guard fileManager.isExecutableFile(atPath: installedPath.path),
              fileManager.isExecutableFile(atPath: bundledPath.path) else {
            return true
        }
        return !fileManager.contentsEqual(atPath: installedPath.path, andPath: bundledPath.path)
    }

    private func shouldRefreshInstalledRemoteBinary(at binaryURL: URL, from sourceURL: URL) -> Bool {
        guard let binaryDate = modificationDate(for: binaryURL) else {
            return true
        }

        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: sourceURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        for case let candidate as URL in enumerator {
            guard ["go", "mod", "sum"].contains(candidate.pathExtension) else { continue }
            guard let sourceDate = modificationDate(for: candidate), sourceDate > binaryDate else { continue }
            return true
        }

        return false
    }

    private func modificationDate(for url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private func bundledRemoteBinaryPath() -> URL? {
        if let bundlePath = Chau7Resources.bundle.url(forResource: "chau7-remote", withExtension: nil) {
            return bundlePath
        }

        if let resourcesURL = Chau7Resources.bundle.resourceURL {
            let candidate = resourcesURL.appendingPathComponent("chau7-remote")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }

    private func installedRemoteBinaryPath() -> URL? {
        dataDirectory()?.appendingPathComponent("chau7-remote")
    }

    private func devRemoteBinaryPath() -> URL? {
        guard let projectRoot = projectRootURL() else { return nil }
        let packagedBuildPath = projectRoot
            .appendingPathComponent("apps/chau7-macos/build/remote-agent/chau7-remote")
        if FileManager.default.isExecutableFile(atPath: packagedBuildPath.path) {
            return packagedBuildPath
        }

        let devPath = projectRoot
            .appendingPathComponent("services/chau7-remote/chau7-remote")
        if FileManager.default.isExecutableFile(atPath: devPath.path) {
            return devPath
        }

        let buildPath = projectRoot
            .appendingPathComponent("services/chau7-remote/cmd/chau7-remote/chau7-remote")
        if FileManager.default.isExecutableFile(atPath: buildPath.path) {
            return buildPath
        }

        return nil
    }

    private func remoteAgentSourceURL() -> URL? {
        guard let projectRoot = projectRootURL() else { return nil }
        let sourceURL = projectRoot.appendingPathComponent("services/chau7-remote")
        let goMod = sourceURL.appendingPathComponent("go.mod")
        guard FileManager.default.fileExists(atPath: goMod.path) else { return nil }
        return sourceURL
    }

    /// Six levels up from Sources/Chau7/Sidecar/<this file> — the same depth
    /// as the original Sources/Chau7/Remote location, so the resolved root is
    /// unchanged.
    private func projectRootURL() -> URL? {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func buildRemoteAgent(from sourceURL: URL, outputURL: URL) -> Bool {
        let outputDir = outputURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create remote agent output directory: \(error.localizedDescription, privacy: .public)")
            lastError = "Failed to create remote agent output directory."
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["go", "build", "-o", outputURL.path, "./cmd/chau7-remote"]
        process.currentDirectoryURL = sourceURL

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            logger.error("Failed to launch go build: \(error.localizedDescription, privacy: .public)")
            lastError = "Failed to launch Go build for remote agent."
            return false
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            logger.error("Remote agent build failed: \(output, privacy: .public)")
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                lastError = "Remote agent build failed. Make sure Go is installed."
            } else {
                lastError = "Remote agent build failed. \(trimmed)"
            }
            return false
        }

        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outputURL.path)
        } catch {
            logger.warning("Failed to set remote binary permissions: \(error.localizedDescription, privacy: .public)")
        }

        return true
    }
}
