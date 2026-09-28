import Foundation
import os.log
import Chau7Core

/// Resolves (and, in development, rebuilds) the chau7-remote agent binary.
/// Extracted verbatim from RemoteControlManager, which previously embedded
/// this ~200-line resolution chain: refresh-from-Go-source when the checkout
/// is newer, dev build outputs, the installed App Support copy, the bundled
/// resource (synced into App Support), and a last-resort `go build`.
///
/// Failure detail surfaces through `lastError` so the owning manager can
/// propagate it into its own user-visible error state, exactly as the
/// embedded code did.
///
/// ## Why resolution is off the main actor
///
/// `resolveBinary()` is `async` and does *all* of its work away from the main
/// actor, not just the compile. That matters twice over:
///
/// 1. An `async` function isolated to an actor does **not** release the actor
///    while it runs synchronous code. Walking the Go checkout with
///    `FileManager.enumerator`, `copyItem`-ing the bundled helper, and the
///    byte-for-byte `contentsEqual` in `shouldReplaceInstalledRemoteBinary`
///    are all synchronous, so leaving them on the main actor blocked the UI
///    exactly as before — the compile fix alone only covered the longest step.
/// 2. Resolution is now slow enough that callers must tolerate an `await`,
///    which is why `RemoteControlManager.startAgent` carries a generation
///    guard. See that call site for the launch-safety reasoning.
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

    func resolveBinary() async -> URL? {
        // Capture actor-isolated inputs before hopping. `dataDirectory()` is a
        // closure owned by the manager, so it must be read here on the
        // main actor rather than from the background resolver.
        let resolvedDataDirectory = dataDirectory()
        let resolution = await Self.resolve(
            dataDirectory: resolvedDataDirectory,
            logger: logger
        )
        if let failure = resolution.failure {
            lastError = failure
        }
        return resolution.binary
    }

    /// Outcome of a resolution attempt, carried across the actor hop so the
    /// main-actor side only has to translate it into `lastError`.
    struct Resolution: Sendable {
        let binary: URL?
        /// `nil` on success; otherwise the user-facing failure message.
        let failure: String?
    }

    // MARK: - Resolution (off the main actor)

    nonisolated private static func resolve(
        dataDirectory: URL?,
        logger: Logger
    ) async -> Resolution {
        let installedPath = dataDirectory?.appendingPathComponent("chau7-remote")

        if let sourceURL = remoteAgentSourceURL(),
           let installedPath,
           shouldRefreshInstalledRemoteBinary(at: installedPath, from: sourceURL) {
            if await performBuild(from: sourceURL, outputURL: installedPath, logger: logger),
               FileManager.default.isExecutableFile(atPath: installedPath.path) {
                return Resolution(binary: installedPath, failure: nil)
            }
        }

        if let devPath = devRemoteBinaryPath(),
           FileManager.default.isExecutableFile(atPath: devPath.path) {
            return Resolution(binary: devPath, failure: nil)
        }

        if let installedPath,
           FileManager.default.isExecutableFile(atPath: installedPath.path) {
            return Resolution(binary: installedPath, failure: nil)
        }

        if let bundlePath = bundledRemoteBinaryPath(),
           FileManager.default.isExecutableFile(atPath: bundlePath.path) {
            syncInstalledRemoteBinary(from: bundlePath, to: installedPath, logger: logger)
            if let installedPath,
               FileManager.default.isExecutableFile(atPath: installedPath.path) {
                return Resolution(binary: installedPath, failure: nil)
            }
            return Resolution(binary: bundlePath, failure: nil)
        }

        if let sourceURL = remoteAgentSourceURL(),
           let installedPath,
           await performBuild(from: sourceURL, outputURL: installedPath, logger: logger),
           FileManager.default.isExecutableFile(atPath: installedPath.path) {
            return Resolution(binary: installedPath, failure: nil)
        }

        return Resolution(binary: nil, failure: nil)
    }

    nonisolated private static func syncInstalledRemoteBinary(
        from bundledPath: URL,
        to installedPath: URL?,
        logger: Logger
    ) {
        guard let installedPath else { return }
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

    nonisolated private static func shouldReplaceInstalledRemoteBinary(
        at installedPath: URL,
        with bundledPath: URL
    ) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: installedPath.path) else { return true }
        guard fileManager.isExecutableFile(atPath: installedPath.path),
              fileManager.isExecutableFile(atPath: bundledPath.path) else {
            return true
        }
        return !fileManager.contentsEqual(atPath: installedPath.path, andPath: bundledPath.path)
    }

    /// Walks the whole Go checkout looking for a source file newer than the
    /// installed binary. This is the expensive step — a full recursive
    /// enumeration with a `stat` per candidate — which is why resolution runs
    /// off the main actor.
    nonisolated private static func shouldRefreshInstalledRemoteBinary(
        at binaryURL: URL,
        from sourceURL: URL
    ) -> Bool {
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

    nonisolated private static func modificationDate(for url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    nonisolated private static func bundledRemoteBinaryPath() -> URL? {
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

    nonisolated private static func devRemoteBinaryPath() -> URL? {
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

    nonisolated private static func remoteAgentSourceURL() -> URL? {
        guard let projectRoot = projectRootURL() else { return nil }
        let sourceURL = projectRoot.appendingPathComponent("services/chau7-remote")
        let goMod = sourceURL.appendingPathComponent("go.mod")
        guard FileManager.default.fileExists(atPath: goMod.path) else { return nil }
        return sourceURL
    }

    /// Six levels up from Sources/Chau7/Sidecar/<this file> — the same depth
    /// as the original Sources/Chau7/Remote location, so the resolved root is
    /// unchanged.
    nonisolated private static func projectRootURL() -> URL? {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    // MARK: - Build (off the main actor, concurrently drained)

    /// `go build` is unbounded in wall-clock time, so it runs on a utility
    /// queue rather than blocking whatever actor called `resolveBinary()`.
    /// `SubprocessRunner.capture` drains both pipes concurrently under a
    /// deadline, so a large compile-error dump can never wedge the child.
    nonisolated private static func performBuild(
        from sourceURL: URL,
        outputURL: URL,
        logger: Logger
    ) async -> Bool {
        let outcome: BuildOutcome = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let outputDir = outputURL.deletingLastPathComponent()
                do {
                    try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
                } catch {
                    logger.error("Failed to create remote agent output directory: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(returning: BuildOutcome(
                        succeeded: false,
                        failure: "Failed to create remote agent output directory."
                    ))
                    return
                }

                let result = SubprocessRunner.capture(
                    executablePath: "/usr/bin/env",
                    arguments: ["go", "build", "-o", outputURL.path, "./cmd/chau7-remote"],
                    currentDirectoryURL: sourceURL,
                    timeout: 300,
                    maximumOutputBytes: 1024 * 1024
                )
                let failure = SubprocessFailureMessage.describe(
                    result,
                    notLaunchedMessage: "Failed to launch Go build for remote agent.",
                    timedOutMessage: "Remote agent build timed out after 5 minutes.",
                    missingToolMessage: "Remote agent build failed. Make sure Go is installed."
                )
                continuation.resume(returning: BuildOutcome(succeeded: failure == nil, failure: failure))
            }
        }

        guard outcome.succeeded else {
            if let failure = outcome.failure {
                logger.error("Remote agent build failed: \(failure, privacy: .public)")
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

    /// Result of a build attempt, carried back across the queue hop.
    private struct BuildOutcome: Sendable {
        let succeeded: Bool
        /// `nil` on success; otherwise the user-facing failure message.
        let failure: String?
    }
}
