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
    private let queue = DispatchQueue(label: "com.chau7.memory-pressure", qos: .utility)
    private let stateLock = NSLock()
    private var lastCriticalAt: Date?
    private let criticalSuppressionWindow: TimeInterval = 30

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
        Log.info("MemoryPressureResponder: started")
    }

    func stop() {
        source?.cancel()
        source = nil
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

    private func handleEvent(_ data: DispatchSource.MemoryPressureEvent) {
        let physicalBytes = UInt64(ProcessInfo.processInfo.physicalMemory)
        let usedBytes = reportedResidentBytes()
        let ratioPercent = physicalBytes > 0 ? Int((Double(usedBytes) / Double(physicalBytes)) * 100) : -1

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
