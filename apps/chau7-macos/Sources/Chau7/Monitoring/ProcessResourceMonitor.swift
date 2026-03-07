import Chau7Core
import Darwin
import Foundation

/// Per-process resource snapshot.
struct ProcessResourceInfo: Identifiable {
    let pid: pid_t
    let parentPid: pid_t
    let name: String
    let cpuPercent: Double
    let rssBytes: Int64

    var id: pid_t {
        pid
    }

    var formattedCPU: String {
        String(format: "%.1f%%", cpuPercent)
    }

    var formattedRSS: String {
        let mb = Double(rssBytes) / (1024 * 1024)
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.1f MB", mb)
    }
}

/// Aggregate snapshot of all child processes under a shell PID.
struct ProcessGroupSnapshot {
    let shellPid: pid_t
    let children: [ProcessResourceInfo] // sorted by CPU desc
    let timestamp: Date

    var totalCPU: Double {
        children.reduce(0) { $0 + $1.cpuPercent }
    }

    var totalRSSBytes: Int64 {
        children.reduce(0) { $0 + $1.rssBytes }
    }

    var formattedTotalCPU: String {
        String(format: "%.1f%%", totalCPU)
    }

    var formattedTotalRSS: String {
        let mb = Double(totalRSSBytes) / (1024 * 1024)
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.1f MB", mb)
    }
}

/// On-demand process resource monitor.
/// Polls `ps` on a timer to capture CPU/memory for a shell's child process tree.
/// Only runs while actively needed (hover card visible).
final class ProcessResourceMonitor {

    var onUpdate: ((ProcessGroupSnapshot?) -> Void)?

    private var timer: DispatchSourceTimer?
    /// All reads/writes of `isStopped` and `timer` are synchronized on `queue`.
    private var isStopped = true
    private var shellPID: pid_t = 0
    private let queue = DispatchQueue(label: "com.chau7.processmonitor", qos: .utility)
    private var consecutiveNoDataPolls = 0

    func start(shellPID: pid_t) {
        stop()
        guard shellPID > 0 else { return }

        queue.sync {
            self.shellPID = shellPID
            isStopped = false
            consecutiveNoDataPolls = 0
            scheduleNextPollLocked()
        }
    }

    func stop() {
        queue.sync {
            isStopped = true
            shellPID = 0
            consecutiveNoDataPolls = 0
            timer?.cancel()
            timer = nil
        }
    }

    // MARK: - Private

    private func scheduleNextPollLocked() {
        guard !isStopped else { return }

        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + intervalForNextPoll())
        timer.setEventHandler { [weak self] in
            self?.poll()
        }
        timer.resume()
        self.timer = timer
    }

    private func intervalForNextPoll() -> TimeInterval {
        MonitoringSchedule.nextPollInterval(
            consecutiveNoDataPolls: consecutiveNoDataPolls
        )
    }

    private func poll() {
        guard !isStopped else { return }
        let currentShellPID = shellPID
        guard currentShellPID > 0 else {
            stop()
            return
        }

        let snapshot = captureSnapshot(shellPID: currentShellPID)
        let shouldSchedule = !isStopped
        let shouldPublish = !isStopped

        if snapshot == nil || snapshot?.children.isEmpty == true {
            consecutiveNoDataPolls = min(consecutiveNoDataPolls + 1, MonitoringSchedule.defaultMaxConsecutiveNoDataPolls)
        } else {
            consecutiveNoDataPolls = 0
        }

        if shouldPublish {
            DispatchQueue.main.async { [weak self] in
                self?.onUpdate?(snapshot)
            }
        }

        if shouldSchedule {
            queue.async { [weak self] in
                self?.scheduleNextPollLocked()
            }
        }
    }

    private func captureSnapshot(shellPID: pid_t) -> ProcessGroupSnapshot? {
        guard let output = runSubprocess(
            executablePath: "/bin/ps",
            arguments: ["-axo", "pid,ppid,rss,%cpu,comm"]
        ) else { return nil }

        // Build parent→children map and per-PID info
        var childrenOf: [pid_t: [pid_t]] = [:]
        var infoOf: [pid_t: (name: String, cpu: Double, rss: Int64)] = [:]

        for line in output.split(separator: "\n") {
            let cols = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard cols.count >= 5,
                  let pid = Int32(cols[0]),
                  let ppid = Int32(cols[1]),
                  let rssKB = Int64(cols[2]),
                  let cpu = Double(cols[3]) else { continue }

            let comm = String(cols[4])
            let name = URL(fileURLWithPath: comm).lastPathComponent

            childrenOf[ppid, default: []].append(pid)
            infoOf[pid] = (name: name, cpu: cpu, rss: rssKB * 1024)
        }

        // BFS from shellPID to collect all descendants (tracking actual parent)
        var descendants: [ProcessResourceInfo] = []
        var bfsQueue: [(pid: pid_t, parent: pid_t)] = (childrenOf[shellPID] ?? []).map { ($0, shellPID) }
        while !bfsQueue.isEmpty {
            let (pid, parent) = bfsQueue.removeFirst()
            if let info = infoOf[pid] {
                descendants.append(ProcessResourceInfo(
                    pid: pid,
                    parentPid: parent,
                    name: info.name,
                    cpuPercent: info.cpu,
                    rssBytes: info.rss
                ))
            }
            if let grandchildren = childrenOf[pid] {
                bfsQueue.append(contentsOf: grandchildren.map { ($0, pid) })
            }
        }

        // Sort by CPU descending
        descendants.sort { $0.cpuPercent > $1.cpuPercent }

        return ProcessGroupSnapshot(
            shellPid: shellPID,
            children: descendants,
            timestamp: Date()
        )
    }

    /// Runs a subprocess and returns stdout. Reaps child to prevent zombies.
    private func runSubprocess(executablePath: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        // Explicitly reap — Foundation.Process on background queues
        // may not run the SIGCHLD handler, leaving a zombie.
        var status: Int32 = 0
        waitpid(process.processIdentifier, &status, WNOHANG)

        return String(decoding: data, as: UTF8.self)
    }
}
