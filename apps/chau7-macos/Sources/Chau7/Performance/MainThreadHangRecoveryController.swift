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
    let observedUptime: TimeInterval?

    init(parentPID: Int32, progressToken: UInt64, observedAt: TimeInterval) {
        self.schemaVersion = 2
        self.observedUptime = ProcessInfo.processInfo.systemUptime
        self.parentPID = parentPID
        self.progressToken = progressToken
        self.observedAt = observedAt
    }
}

private struct MainThreadHangSampleCooldown: Codable {
    let parentPID: Int32
    let sampledAtUptime: TimeInterval
}

private struct MainThreadHangSampleManifest: Codable {
    let schemaVersion: Int
    let detectedAt: Date
    let parentPID: Int32
    let staleMilliseconds: Int
    let samplePath: String
    let sampleExitStatus: Int32?
    let sampleLaunchError: String?
    let sampleTimedOut: Bool
    let sampleTruncated: Bool
    let buildSHA: String
    let buildTimestamp: String
    let operatingSystem: String
    let watchdogPID: Int32
    let heartbeatBeforeCapture: MainThreadHeartbeat
    let heartbeatAfterCapture: MainThreadHeartbeat?
    let captureEvidence: HangSampleEvidence
    let mainThreadStacks: MainThreadStackObservations
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

        // The watchdog exists only to capture a diagnostic sample for a main-thread
        // stall. It must be launched when a stall begins (or is ongoing) and
        // allowed to exit once the main thread is healthy again.
        //
        // Calling `launchIndependentWatchdog()` unconditionally on every tick was
        // harmless only for as long as the child never self-exited: the
        // `watchdogProcess == nil` guard inside then blocked every respawn, and
        // exactly one child lived for the app's whole lifetime. Once the child was
        // taught to retire on recovery, `watchdogProcess?.isRunning == false` became
        // true within a second, the handle was cleared, and the next tick spawned a
        // replacement — which retired, which spawned another. That is a ~3s
        // fork/exec loop, observed 2806 times in one session.
        //
        // So: respawn only while a stall is actually in progress, and never
        // resurrect a child the moment the main thread is healthy.
        switch MainThreadHangWatchdogLifetime.launchAction(
            phaseIsStalled: observation.phase == .stalled,
            enteredStall: observation.enteredStall,
            existingWatchdogRunning: watchdogProcess?.isRunning
        ) {
        case .launch:
            launchIndependentWatchdog()
        case .replace:
            Log.info("Hang watchdog exited during an ongoing stall; scheduling replacement")
            watchdogProcess = nil
            launchIndependentWatchdog()
        case .idle:
            // Main thread is healthy: drop the handle so a later stall spawns a
            // fresh child. The child terminates itself; we are not killing it.
            watchdogProcess = nil
        }

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
        let cooldownURL = outputDirectoryURL.appendingPathComponent("last-sample.json")
        let previousSample = (try? Data(contentsOf: cooldownURL)).flatMap {
            try? JSONDecoder().decode(MainThreadHangSampleCooldown.self, from: $0)
        }
        let lastSampleAt = previousSample.flatMap { record -> TimeInterval? in
            guard record.parentPID == command.parentPID,
                  record.sampledAtUptime <= ProcessInfo.processInfo.systemUptime else { return nil }
            return record.sampledAtUptime
        }
        var lifetime = MainThreadHangWatchdogLifetime(startedAt: ProcessInfo.processInfo.systemUptime)

        while parentIsAlive(command.parentPID) {
            var healthy = false
            var capturedSampleNow = false
            var heartbeatReadable = true

            autoreleasepool {
                guard let data = try? Data(contentsOf: heartbeatURL),
                      let heartbeat = try? JSONDecoder().decode(MainThreadHeartbeat.self, from: data),
                      heartbeat.parentPID == command.parentPID else {
                    // No readable heartbeat means the parent is gone or the
                    // controller stopped; either way there is nothing to watch.
                    heartbeatReadable = false
                    return
                }

                let now = ProcessInfo.processInfo.systemUptime
                if state == nil {
                    state = MainThreadHangMonitorState(
                        initialProgressToken: heartbeat.progressToken,
                        now: min(now, heartbeat.observedUptime ?? now),
                        lastSampleAt: lastSampleAt
                    )
                }
                guard var currentState = state else {
                    heartbeatReadable = false
                    return
                }
                let observation = currentState.observe(
                    progressToken: heartbeat.progressToken,
                    now: now,
                    policy: policy
                )
                state = currentState
                healthy = observation.phase == .healthy
                if observation.shouldSample {
                    // Persist before sampling: the child exits on recovery, but
                    // the 60-second diagnostic budget must survive its replacement.
                    let cooldown = MainThreadHangSampleCooldown(parentPID: command.parentPID, sampledAtUptime: now)
                    if let encoded = try? JSONEncoder().encode(cooldown) {
                        try? encoded.write(to: cooldownURL, options: .atomic)
                    }
                    captureSample(
                        parentPID: command.parentPID,
                        staleFor: observation.staleFor,
                        heartbeatBeforeCapture: heartbeat,
                        heartbeatURL: heartbeatURL,
                        outputDirectoryURL: outputDirectoryURL
                    )
                    capturedSampleNow = true
                }
            }

            if !heartbeatReadable { break }

            let now = ProcessInfo.processInfo.systemUptime
            lifetime.observe(
                isHealthy: healthy,
                capturedSampleNow: capturedSampleNow,
                now: now
            )
            // Exit once the main thread is advancing again. See
            // `MainThreadHangWatchdogLifetime` for why a watchdog that outlives
            // its own stall is a liability rather than a safety net.
            if lifetime.shouldExit(parentIsAlive: parentIsAlive(command.parentPID), now: now) {
                break
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
        heartbeatBeforeCapture: MainThreadHeartbeat,
        heartbeatURL: URL,
        outputDirectoryURL: URL
    ) {
        let startedUptime = ProcessInfo.processInfo.systemUptime
        let detectedAt = Date()
        let stem = "hang-\(Int(detectedAt.timeIntervalSince1970))-pid-\(parentPID)"
        let sampleURL = outputDirectoryURL.appendingPathComponent("\(stem).sample.txt")
        let manifestURL = outputDirectoryURL.appendingPathComponent("\(stem).json")
        var exitStatus: Int32?
        var launchError: String?
        var timedOut = false
        var truncated = false

        do {
            try FileManager.default.createDirectory(at: outputDirectoryURL, withIntermediateDirectories: true)
            // This deadline covers only our diagnostic helper. The shell-owning app
            // is never terminated or relaunched, even if its UI cannot recover.
            if let result = SubprocessRunner.capture(
                executablePath: "/usr/bin/sample",
                arguments: ["\(parentPID)", "5", "10", "-file", sampleURL.path],
                timeout: 10,
                maximumOutputBytes: 64 * 1024
            ) {
                exitStatus = result.status
                timedOut = result.timedOut
                if result.outputLimitExceeded { launchError = "Diagnostic helper exceeded output budget" }
                if result.readFailed { launchError = "Diagnostic helper output could not be read" }
            } else {
                launchError = "Diagnostic helper could not be launched"
            }
            let size = try sampleURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            if size > 8 * 1024 * 1024 {
                let file = try FileHandle(forWritingTo: sampleURL)
                defer { try? file.close() }
                try file.truncate(atOffset: 8 * 1024 * 1024)
                truncated = true
            }
        } catch {
            launchError = String(describing: error)
        }

        let completedUptime = ProcessInfo.processInfo.systemUptime
        let afterData = try? Data(contentsOf: heartbeatURL)
        let decodedAfter = afterData.flatMap { try? JSONDecoder().decode(MainThreadHeartbeat.self, from: $0) }
        let heartbeatAfter = decodedAfter?.parentPID == parentPID ? decodedAfter : nil
        let evidence = HangSampleEvidence(
            beforeToken: heartbeatBeforeCapture.progressToken,
            afterToken: heartbeatAfter?.progressToken,
            startedUptime: startedUptime,
            completedUptime: completedUptime
        )
        var sampleText = ""
        if let file = try? FileHandle(forReadingFrom: sampleURL) {
            defer { try? file.close() }
            if let data = try? file.read(upToCount: MainThreadStackObservations.maximumInputBytes + 1) {
                sampleText = String(decoding: data, as: UTF8.self)
            }
        }
        let info = Bundle.main.infoDictionary ?? [:]
        let manifest = MainThreadHangSampleManifest(
            schemaVersion: 3,
            detectedAt: detectedAt,
            parentPID: parentPID,
            staleMilliseconds: Int(min(Double(Int.max / 2), max(0, staleFor * 1000))),
            samplePath: sampleURL.path,
            sampleExitStatus: exitStatus,
            sampleLaunchError: launchError,
            sampleTimedOut: timedOut,
            sampleTruncated: truncated,
            buildSHA: info["Chau7BuildGitSHA"] as? String ?? "unknown",
            buildTimestamp: info["Chau7BuildTimestamp"] as? String ?? "unknown",
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            watchdogPID: getpid(),
            heartbeatBeforeCapture: heartbeatBeforeCapture,
            heartbeatAfterCapture: heartbeatAfter,
            captureEvidence: evidence,
            mainThreadStacks: MainThreadStackObservations(sampleText: sampleText)
        )
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: manifestURL, options: .atomic)
            try? data.write(to: outputDirectoryURL.appendingPathComponent("latest-hang.json"), options: .atomic)
        }
        pruneDiagnostics(in: outputDirectoryURL, now: detectedAt)
    }

    /// Only recognized diagnostic bundles are eligible. Heartbeats and unrelated
    /// files stay untouched; paired samples/manifests retire together.
    static func pruneDiagnostics(in directory: URL, now: Date = Date()) {
        let manager = FileManager.default
        guard let urls = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]) else { return }
        var groups: [String: (urls: [URL], bytes: Int, modifiedAt: TimeInterval)] = [:]
        for url in urls {
            let name = url.lastPathComponent
            guard name.hasPrefix("hang-"), name.hasSuffix(".json") || name.hasSuffix(".sample.txt"),
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
            let stem = name.hasSuffix(".sample.txt") ? String(name.dropLast(11)) : String(name.dropLast(5))
            var group = groups[stem] ?? ([], 0, 0)
            group.urls.append(url)
            group.bytes += values.fileSize ?? 0
            group.modifiedAt = max(group.modifiedAt, values.contentModificationDate?.timeIntervalSince1970 ?? 0)
            groups[stem] = group
        }
        let entries = groups.map { FileRetentionBudget.Entry(key: $0.key, bytes: $0.value.bytes, modifiedAt: $0.value.modifiedAt) }
            .sorted { $0.modifiedAt == $1.modifiedAt ? $0.key > $1.key : $0.modifiedAt > $1.modifiedAt }
        let removed = FileRetentionBudget.removals(
            newestFirst: entries,
            maximumCount: 40,
            maximumBytes: 64 * 1024 * 1024,
            maximumFileBytes: 8 * 1024 * 1024 + 64 * 1024,
            cutoff: now.addingTimeInterval(-7 * 86400).timeIntervalSince1970
        )
        for key in removed {
            for url in groups[key]?.urls ?? [] {
                try? manager.removeItem(at: url)
            }
        }
    }
}
