import Foundation
import os.log

/// Owns the shared process lifecycle of an embedded Go sidecar
/// (chau7-remote, chau7-proxy): marking the binary executable, constructing
/// the `Process` (working directory, environment, stdout/stderr pipes),
/// draining pipe output through `ManagedProcess.monitorOutput`, surfacing
/// unexpected exits on the main actor, and terminating on stop.
///
/// Everything that differs between sidecars — environment variables, output
/// log routing, restart policy, status notifications — stays with the owning
/// manager and is injected through `Configuration`. This type is deliberately
/// mechanical: it replaces the duplicated Process bookkeeping that previously
/// lived in both RemoteControlManager and ProxyManager.
@MainActor
final class ManagedGoSidecar {

    struct Configuration {
        /// Human-readable process label used in permission/termination logs
        /// ("remote agent", "proxy").
        var name: String
        var logger: Logger
        /// `stop()` teardown order. The proxy historically detaches pipe
        /// monitoring before signalling the process; the remote agent
        /// terminates first (avoiding SIGPIPE on the agent side).
        var stopsPipeMonitoringBeforeTerminate: Bool
        /// Receives raw stdout chunks. Called on a background queue; the
        /// handler is responsible for decoding and any thread hops.
        var onStdoutData: (Data) -> Void
        /// Receives raw stderr chunks. Called on a background queue.
        var onStderrData: (Data) -> Void
        /// Called on the main actor with the termination status when the
        /// process exits on its own. `stop()` detaches the termination
        /// handler first, so clean stops never fire this.
        var onExit: @MainActor (Int32) -> Void
    }

    struct LaunchSpec {
        var binaryURL: URL
        var arguments: [String] = []
        var currentDirectoryURL: URL
        /// Full environment for the child (callers start from
        /// `ProcessInfo.processInfo.environment` and layer sidecar-specific
        /// variables on top).
        var environment: [String: String]
    }

    private let configuration: Configuration
    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Whether a launched process is still tracked. Stays `true` after an
    /// unexpected exit until `stop()` or `clearProcessAfterExit()` runs,
    /// mirroring the managers' historical `process != nil` checks.
    var hasProcess: Bool {
        process != nil
    }

    var isProcessRunning: Bool {
        process?.isRunning ?? false
    }

    /// Marks the binary executable (warning on failure, matching both
    /// managers' historical chmod-and-continue behavior) and launches it.
    /// Rethrows the `Process.run` error; no state is stored on failure.
    func launch(_ spec: LaunchSpec) throws {
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: spec.binaryURL.path
            )
        } catch {
            let name = configuration.name
            configuration.logger.warning("Failed to set \(name, privacy: .public) binary permissions: \(error.localizedDescription, privacy: .public)")
        }

        let process = Process()
        process.executableURL = spec.binaryURL
        if !spec.arguments.isEmpty {
            process.arguments = spec.arguments
        }
        process.currentDirectoryURL = spec.currentDirectoryURL
        process.environment = spec.environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe

        // Capture the handlers locally so the background readabilityHandler
        // never reads main-actor state.
        let onStdout = configuration.onStdoutData
        ManagedProcess.monitorOutput(of: outputPipe) { data in
            onStdout(data)
        }
        let onStderr = configuration.onStderrData
        ManagedProcess.monitorOutput(of: errorPipe) { data in
            onStderr(data)
        }

        let onExit = configuration.onExit
        process.terminationHandler = { proc in
            let status = proc.terminationStatus
            Task { @MainActor in
                onExit(status)
            }
        }

        try process.run()
        self.process = process
    }

    /// Detaches the termination handler (so `onExit` never fires for a
    /// deliberate stop), tears down pipe monitoring and terminates the
    /// process in the configured order, then drops the process reference.
    /// No-op when nothing was launched.
    func stop() {
        guard let process else { return }
        process.terminationHandler = nil
        if configuration.stopsPipeMonitoringBeforeTerminate {
            ManagedProcess.cleanup(outputPipe: &outputPipe, errorPipe: &errorPipe)
            ManagedProcess.terminate(process, name: configuration.name, logger: configuration.logger)
        } else {
            // Terminate the process BEFORE closing pipes to avoid SIGPIPE.
            ManagedProcess.terminate(process, name: configuration.name, logger: configuration.logger)
            ManagedProcess.cleanup(outputPipe: &outputPipe, errorPipe: &errorPipe)
        }
        self.process = nil
    }

    /// Drops the stale `Process` reference and detaches pipe monitoring after
    /// an unexpected exit. Exit handlers that want fresh-launch semantics
    /// (the proxy's historical behavior) call this; the remote agent
    /// deliberately keeps its stale reference so a later `stopAgent()` still
    /// runs its state resets.
    func clearProcessAfterExit() {
        process = nil
        ManagedProcess.cleanup(outputPipe: &outputPipe, errorPipe: &errorPipe)
    }
}
