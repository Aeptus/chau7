import Foundation

/// Listens to macOS memory pressure notifications, records a breadcrumb for
/// correlation, and drives actual reclamation through `MemoryPressureCoordinator`,
/// which broadcasts to every registered `MemoryReclaimable` cache.
///
/// On `.warning`: shed cheap, fully-regenerable memory (e.g. trim transcript rings).
/// On `.critical`: release reclaimable memory aggressively, and treat the signal as
/// a short-lived hint to skip best-effort output work (see `shouldShedBestEffortOutputWork`).
final class MemoryPressureResponder {
    static let shared = MemoryPressureResponder()

    private var source: DispatchSourceMemoryPressure?
    private var footprintTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.chau7.memory-pressure", qos: .utility)
    private let stateLock = NSLock()
    private var lastCriticalAt: Date?
    private let criticalSuppressionWindow: TimeInterval = 30
    private var lastPressureAt: Date?
    private let memoryPressureWindow: TimeInterval = 90
    private var lastSelfTriggerAt: Date?
    private let selfTriggerCooldown: TimeInterval = 60
    private static let footprintCheckInterval: TimeInterval = 30

    private init() {}

    func start() {
        guard source == nil else { return }
        let pressureSource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: queue
        )
        pressureSource.setEventHandler { [weak self] in
            self?.handleEvent(pressureSource.data)
        }
        pressureSource.resume()
        source = pressureSource

        // Proactive ceiling check: on big-RAM Macs the OS pressure signal
        // fires very late (the 31GB incident hit jetsam before any signal
        // shrank a cache). Poll our own phys_footprint and synthesize
        // pressure when it crosses the self-imposed ceiling, driving the
        // same demote-to-.hidden + reclaim machinery the OS signal does.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Self.footprintCheckInterval,
            repeating: Self.footprintCheckInterval,
            leeway: .seconds(5)
        )
        timer.setEventHandler { [weak self] in
            self?.checkFootprintCeiling()
        }
        timer.resume()
        footprintTimer = timer

        Log.info("MemoryPressureResponder: started")
    }

    func stop() {
        source?.cancel()
        source = nil
        footprintTimer?.cancel()
        footprintTimer = nil
    }

    /// Self-imposed footprint ceiling: a quarter of physical memory, clamped
    /// to [4GB, 12GB]. A terminal that grows past this has runaway
    /// accumulation regardless of how much RAM the machine has.
    static func footprintCeilingBytes(physicalBytes: UInt64) -> UInt64 {
        let quarter = physicalBytes / 4
        let floor: UInt64 = 4 << 30
        let cap: UInt64 = 12 << 30
        return min(max(quarter, floor), cap)
    }

    private func checkFootprintCeiling(now: Date = Date()) {
        let used = reportedResidentBytes()
        guard used > 0 else { return }
        let physical = UInt64(ProcessInfo.processInfo.physicalMemory)
        let ceiling = Self.footprintCeilingBytes(physicalBytes: physical)
        guard used > ceiling else { return }

        stateLock.lock()
        let recentlyTriggered = lastSelfTriggerAt.map { now.timeIntervalSince($0) < selfTriggerCooldown } ?? false
        if !recentlyTriggered {
            lastSelfTriggerAt = now
            lastPressureAt = now
        }
        stateLock.unlock()
        guard !recentlyTriggered else { return }

        // 1.5x the ceiling escalates to the aggressive tier.
        let level: MemoryPressureLevel = used > ceiling + ceiling / 2 ? .critical : .warning
        if level == .critical {
            stateLock.lock()
            lastCriticalAt = now
            stateLock.unlock()
        }
        let reclaimed = MemoryPressureCoordinator.shared.reclaim(level)
        NotificationCenter.default.post(name: .chau7MemoryPressureChanged, object: nil)
        IncidentBreadcrumbStore.shared.recordMemoryPressure(
            level: level == .critical ? .critical : .warning,
            residentBytes: used,
            physicalBytes: physical,
            reclaimedBytes: reclaimed,
            synchronously: level == .critical
        )
        Log.warn(
            "MemoryPressureResponder: self-imposed footprint ceiling exceeded " +
                "(rss=\(used / (1024 * 1024))MB > ceiling=\(ceiling / (1024 * 1024))MB) — " +
                "synthesized \(level) pressure (reclaimed=\(reclaimed / (1024 * 1024))MB)"
        )
    }

    /// The OS pressure API does not emit a "back to normal" event. Treat a
    /// recent critical signal as a short-lived hint to skip best-effort work
    /// rather than latching the app into a permanent degraded mode.
    func shouldShedBestEffortOutputWork(now: Date = Date()) -> Bool {
        stateLock.lock()
        let lastCriticalAt = lastCriticalAt
        stateLock.unlock()
        guard let lastCriticalAt else { return false }
        return now.timeIntervalSince(lastCriticalAt) < criticalSuppressionWindow
    }

    /// True while the app has seen OS memory pressure (warning or critical) recently.
    /// Biases the render-lifecycle policy toward demoting non-selected tabs to `.hidden`
    /// so their scrollback is flushed to disk. Under sustained pressure the OS re-fires
    /// every few minutes, refreshing the window; when pressure ends, this clears and
    /// tabs are restored to `.warm` on the next lifecycle re-evaluation.
    func isUnderMemoryPressure(now: Date = Date()) -> Bool {
        stateLock.lock()
        let lastPressureAt = lastPressureAt
        stateLock.unlock()
        guard let lastPressureAt else { return false }
        return now.timeIntervalSince(lastPressureAt) < memoryPressureWindow
    }

    private func handleEvent(_ data: DispatchSource.MemoryPressureEvent) {
        let physicalBytes = UInt64(ProcessInfo.processInfo.physicalMemory)
        let usedBytes = reportedResidentBytes()
        let ratioPercent = physicalBytes > 0 ? Int((Double(usedBytes) / Double(physicalBytes)) * 100) : -1

        if data.contains(.warning) || data.contains(.critical) {
            stateLock.lock()
            lastPressureAt = Date()
            stateLock.unlock()
            // Wake render-lifecycle observers so non-selected tabs demote and flush
            // their scrollback while pressure persists.
            NotificationCenter.default.post(name: .chau7MemoryPressureChanged, object: nil)
        }

        if data.contains(.critical) {
            stateLock.lock()
            lastCriticalAt = Date()
            stateLock.unlock()
            let reclaimed = MemoryPressureCoordinator.shared.reclaim(.critical)
            IncidentBreadcrumbStore.shared.recordMemoryPressure(
                level: .critical,
                residentBytes: usedBytes,
                physicalBytes: physicalBytes,
                reclaimedBytes: reclaimed,
                synchronously: true
            )
            Log.warn(
                "MemoryPressureResponder: CRITICAL pressure " +
                    "(process rss=\(usedBytes / (1024 * 1024))MB, \(ratioPercent)% of \(physicalBytes / (1024 * 1024))MB physical, " +
                    "reclaimed=\(reclaimed / (1024 * 1024))MB)"
            )
        } else if data.contains(.warning) {
            let reclaimed = MemoryPressureCoordinator.shared.reclaim(.warning)
            IncidentBreadcrumbStore.shared.recordMemoryPressure(
                level: .warning,
                residentBytes: usedBytes,
                physicalBytes: physicalBytes,
                reclaimedBytes: reclaimed,
                synchronously: false
            )
            Log.info(
                "MemoryPressureResponder: warning pressure " +
                    "(process rss=\(usedBytes / (1024 * 1024))MB, \(ratioPercent)% of \(physicalBytes / (1024 * 1024))MB physical, " +
                    "reclaimed=\(reclaimed / (1024 * 1024))MB)"
            )
        }
    }

    private func reportedResidentBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result: kern_return_t = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return info.phys_footprint
    }
}

extension Notification.Name {
    /// Posted when the app enters (or re-confirms) OS memory pressure. Observers
    /// re-evaluate the render lifecycle so non-selected tabs flush their scrollback.
    static let chau7MemoryPressureChanged = Notification.Name("com.chau7.memoryPressureChanged")
}
