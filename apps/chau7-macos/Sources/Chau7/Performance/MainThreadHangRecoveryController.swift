import Atomics
import Chau7Core
import Darwin
import Foundation

/// Global, lock-free brake for terminal paint work. It is opened only after a
/// confirmed main-thread heartbeat stall; PTY reads, parsing, scrollback, and
/// persistence continue untouched, so recovery never sacrifices shell data.
final class TerminalRenderCircuitBreaker {
    static let shared = TerminalRenderCircuitBreaker()

    private let open = ManagedAtomic(false)

    var isOpen: Bool {
        open.load(ordering: .acquiring)
    }

    @discardableResult
    func setOpen(_ value: Bool) -> Bool {
        open.exchange(value, ordering: .acquiringAndReleasing) != value
    }
}

private struct MainThreadHeartbeat: Codable {
    let schemaVersion: Int
    let parentPID: Int32
    let progressToken: UInt64
    let observedAt: TimeInterval

    init(parentPID: Int32, progressToken: UInt64, observedAt: TimeInterval) {
        self.schemaVersion = 1
        self.parentPID = parentPID
        self.progressToken = progressToken
        self.observedAt = observedAt
    }
}

private struct MainThreadHangSampleManifest: Codable {
    let schemaVersion: Int
    let detectedAt: Date
    let parentPID: Int32
    let staleMilliseconds: Int
    let samplePath: String
    let sampleExitStatus: Int32?
    let sampleLaunchError: String?
}

/// Supervises the main event loop without ever synchronously consulting it.
/// A tiny main-queue timer advances an atomic token; a dedicated queue opens a
/// render circuit breaker after two seconds without progress, while a separate
/// Chau7 watchdog process captures a `sample` even if the app cannot recover.
final class MainThreadHangRecoveryController {
    static let shared = MainThreadHangRecoveryController()

    private static let heartbeatInterval: DispatchTimeInterval = .milliseconds(250)
    private static let monitorInterval: DispatchTimeInterval = .milliseconds(250)
    private static let heartbeatFileInterval: TimeInterval = 1

    private let policy = MainThreadHangMonitorPolicy()
    private let progressToken = ManagedAtomic<UInt64>(0)
    private let running = ManagedAtomic(false)
    private let monitorQueue = DispatchQueue(
        label: "com.chau7.main-thread-hang-monitor",
        qos: .userInitiated
    )

    private var mainHeartbeatTimer: DispatchSourceTimer?
    // The remaining mutable fields are confined to monitorQueue.
    private var monitorTimer: DispatchSourceTimer?
    private var monitorState: MainThreadHangMonitorState?
    private var lastHeartbeatWriteAt: TimeInterval = -.infinity
    private var lastWrittenProgressToken: UInt64?
    private var watchdogProcess: Process?
    private var lastWatchdogLaunchAttemptAt: TimeInterval = -.infinity

    private init() {}

    func start() {
        guard !RuntimeIsolation.isIsolatedTestMode() else { return }
        guard !running.exchange(true, ordering: .acquiringAndReleasing) else { return }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now(),
            repeating: Self.heartbeatInterval,
            leeway: .milliseconds(25)
        )
        timer.setEventHandler { [weak self] in
            self?.progressToken.wrappingIncrement(ordering: .releasing)
        }
        mainHeartbeatTimer = timer
        timer.resume()

        monitorQueue.async { [weak self] in
            self?.startBackgroundMonitor()
        }
    }

    func stop() {
        guard running.exchange(false, ordering: .acquiringAndReleasing) else { return }
        mainHeartbeatTimer?.cancel()
        mainHeartbeatTimer = nil
        _ = TerminalRenderCircuitBreaker.shared.setOpen(false)

        monitorQueue.async { [weak self] in
            guard let self else { return }
            monitorTimer?.cancel()
            monitorTimer = nil
            if let watchdogProcess, watchdogProcess.isRunning {
                watchdogProcess.terminate()
            }
            watchdogProcess = nil
            try? FileManager.default.removeItem(at: heartbeatURL)
        }
    }

    private var outputDirectoryURL: URL {
        RuntimeIsolation.appSupportDirectory(named: "Chau7")
            .appendingPathComponent("HangDiagnostics", isDirectory: true)
    }

    private var heartbeatURL: URL {
        outputDirectoryURL.appendingPathComponent("main-thread-heartbeat.json")
    }

    private func startBackgroundMonitor() {
        guard running.load(ordering: .acquiring) else { return }
        do {
            try FileManager.default.createDirectory(
                at: outputDirectoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            Log.warn("MainThreadHangRecoveryController: cannot create diagnostics directory: \(error)")
        }

        let now = Self.monotonicTime()
        let token = progressToken.load(ordering: .acquiring)
        monitorState = MainThreadHangMonitorState(initialProgressToken: token, now: now)
        writeHeartbeat(progressToken: token, wallTime: Date().timeIntervalSince1970)
        launchIndependentWatchdog()

        let timer = DispatchSource.makeTimerSource(queue: monitorQueue)
        timer.schedule(
            deadline: .now() + Self.monitorInterval,
            repeating: Self.monitorInterval,
            leeway: .milliseconds(25)
        )
        timer.setEventHandler { [weak self] in
            self?.monitorTick()
        }
        monitorTimer = timer
        timer.resume()
    }

    private func monitorTick() {
        guard running.load(ordering: .acquiring), var state = monitorState else { return }

        let now = Self.monotonicTime()
        let token = progressToken.load(ordering: .acquiring)
        let observation = state.observe(progressToken: token, now: now, policy: policy)
        monitorState = state

        if token != lastWrittenProgressToken,
           now - lastHeartbeatWriteAt >= Self.heartbeatFileInterval {
            writeHeartbeat(progressToken: token, wallTime: Date().timeIntervalSince1970)
        }
        if watchdogProcess?.isRunning == false {
            Log.warn("Independent hang watchdog exited; scheduling replacement")
            watchdogProcess = nil
        }
        launchIndependentWatchdog()

        if observation.enteredStall {
            let changed = TerminalRenderCircuitBreaker.shared.setOpen(true)
            if changed {
                IncidentBreadcrumbStore.shared.record(
                    kind: .mainThreadHang,
                    severity: .critical,
                    message: "Main thread heartbeat stalled; terminal paint circuit breaker opened",
                    metadata: [
                        "parentPID": "\(ProcessInfo.processInfo.processIdentifier)",
                        "staleMilliseconds": "\(Int(observation.staleFor * 1000))",
                        "diagnosticsDirectory": outputDirectoryURL.path
                    ]
                )
                Log.error(
                    "Main thread heartbeat stalled for \(String(format: "%.2f", observation.staleFor))s; " +
                        "terminal paint circuit breaker opened"
                )
            }
        } else if observation.recovered {
            let changed = TerminalRenderCircuitBreaker.shared.setOpen(false)
            if changed {
                IncidentBreadcrumbStore.shared.record(
                    kind: .mainThreadHang,
                    severity: .info,
                    message: "Main thread heartbeat recovered; terminal paint circuit breaker closed",
                    metadata: [
                        "parentPID": "\(ProcessInfo.processInfo.processIdentifier)",
                        "stallMilliseconds": "\(Int(observation.staleFor * 1000))"
                    ]
                )
                Log.info(
                    "Main thread heartbeat recovered after \(String(format: "%.2f", observation.staleFor))s; " +
                        "terminal paint circuit breaker closed"
                )
            }
        }
    }

    private func writeHeartbeat(progressToken: UInt64, wallTime: TimeInterval) {
        let heartbeat = MainThreadHeartbeat(
            parentPID: ProcessInfo.processInfo.processIdentifier,
            progressToken: progressToken,
            observedAt: wallTime
        )
        do {
            let data = try JSONEncoder().encode(heartbeat)
            // This diagnostic can tolerate one partial read; the watchdog
            // retries four times per second. Avoid an APFS rename every second.
            try data.write(to: heartbeatURL)
            lastWrittenProgressToken = progressToken
            lastHeartbeatWriteAt = Self.monotonicTime()
        } catch {
            Log.warn("MainThreadHangRecoveryController: heartbeat write failed: \(error)")
        }
    }

    private func launchIndependentWatchdog() {
        guard watchdogProcess == nil else { return }
        let now = Self.monotonicTime()
        guard now - lastWatchdogLaunchAttemptAt >= 5 else { return }
        lastWatchdogLaunchAttemptAt = now
        guard let executableURL = Bundle.main.executableURL else {
            Log.warn("MainThreadHangRecoveryController: app executable URL unavailable")
            return
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "--hang-watchdog",
            "--parent-pid", "\(ProcessInfo.processInfo.processIdentifier)",
            "--heartbeat", heartbeatURL.path,
            "--output-directory", outputDirectoryURL.path
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            watchdogProcess = process
            Log.info("Independent hang watchdog started pid=\(process.processIdentifier)")
        } catch {
            Log.warn("MainThreadHangRecoveryController: failed to launch independent watchdog: \(error)")
        }
    }

    private static func monotonicTime() -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}

/// Blocking command-mode runner used only in Chau7's watchdog child process.
/// It never sends a signal to the parent; `kill(pid, 0)` is solely a liveness
/// query. Its only intervention is an external `/usr/bin/sample` capture.
enum MainThreadHangWatchdogRunner {
    static func run(command: MainThreadHangWatchdogCommand) {
        let heartbeatURL = URL(fileURLWithPath: command.heartbeatPath)
        let outputDirectoryURL = URL(fileURLWithPath: command.outputDirectoryPath, isDirectory: true)
        let policy = MainThreadHangMonitorPolicy()
        var state: MainThreadHangMonitorState?

        while parentIsAlive(command.parentPID) {
            autoreleasepool {
                guard let data = try? Data(contentsOf: heartbeatURL),
                      let heartbeat = try? JSONDecoder().decode(MainThreadHeartbeat.self, from: data),
                      heartbeat.parentPID == command.parentPID else {
                    return
                }

                let now = Date().timeIntervalSince1970
                if state == nil {
                    state = MainThreadHangMonitorState(
                        initialProgressToken: heartbeat.progressToken,
                        now: min(now, heartbeat.observedAt)
                    )
                }
                guard var currentState = state else { return }
                let observation = currentState.observe(
                    progressToken: heartbeat.progressToken,
                    now: now,
                    policy: policy
                )
                state = currentState
                if observation.shouldSample {
                    captureSample(
                        parentPID: command.parentPID,
                        staleFor: observation.staleFor,
                        outputDirectoryURL: outputDirectoryURL
                    )
                }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    private static func parentIsAlive(_ pid: Int32) -> Bool {
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func captureSample(
        parentPID: Int32,
        staleFor: TimeInterval,
        outputDirectoryURL: URL
    ) {
        let detectedAt = Date()
        let stem = "hang-\(Int(detectedAt.timeIntervalSince1970))-pid-\(parentPID)"
        let sampleURL = outputDirectoryURL.appendingPathComponent("\(stem).sample.txt")
        let manifestURL = outputDirectoryURL.appendingPathComponent("\(stem).json")
        var exitStatus: Int32?
        var launchError: String?

        do {
            try FileManager.default.createDirectory(
                at: outputDirectoryURL,
                withIntermediateDirectories: true
            )
            let sample = Process()
            sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            sample.arguments = [
                "\(parentPID)",
                "5",
                "10",
                "-file", sampleURL.path
            ]
            sample.standardInput = FileHandle.nullDevice
            sample.standardOutput = FileHandle.nullDevice
            sample.standardError = FileHandle.nullDevice
            try sample.run()
            sample.waitUntilExit()
            exitStatus = sample.terminationStatus
        } catch {
            launchError = String(describing: error)
        }

        let manifest = MainThreadHangSampleManifest(
            schemaVersion: 1,
            detectedAt: detectedAt,
            parentPID: parentPID,
            staleMilliseconds: Int(staleFor * 1000),
            samplePath: sampleURL.path,
            sampleExitStatus: exitStatus,
            sampleLaunchError: launchError
        )
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: manifestURL, options: .atomic)
        }
    }
}
