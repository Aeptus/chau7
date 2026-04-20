import Foundation

/// Listens to macOS memory pressure notifications and logs them so we can
/// correlate memory spikes with user-visible behavior. The actual reclamation
/// is delegated to ScrollbackMemoryManager, which already flushes hidden tabs
/// on phase transition — the pressure signal is a secondary hint that we
/// should be more aggressive about demoting marginal tabs.
///
/// On `.warning`: log the event. Hidden-tab scrollback reclamation handles the
/// safe cases; visible tabs keep their configured history.
///
/// On `.critical`: log prominently. If we add an explicit "demote all
/// non-active tabs" action later, this is where it will hook in.
final class MemoryPressureResponder {
    static let shared = MemoryPressureResponder()

    private var source: DispatchSourceMemoryPressure?
    private let queue = DispatchQueue(label: "com.chau7.memory-pressure", qos: .utility)

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

    private func handleEvent(_ data: DispatchSource.MemoryPressureEvent) {
        let physicalBytes = UInt64(ProcessInfo.processInfo.physicalMemory)
        let usedBytes = reportedResidentBytes()
        let ratioPercent = physicalBytes > 0 ? Int((Double(usedBytes) / Double(physicalBytes)) * 100) : -1

        if data.contains(.critical) {
            Log.warn(
                "MemoryPressureResponder: CRITICAL pressure " +
                    "(process rss=\(usedBytes / (1024 * 1024))MB, \(ratioPercent)% of \(physicalBytes / (1024 * 1024))MB physical)"
            )
        } else if data.contains(.warning) {
            Log.info(
                "MemoryPressureResponder: warning pressure " +
                    "(process rss=\(usedBytes / (1024 * 1024))MB, \(ratioPercent)% of \(physicalBytes / (1024 * 1024))MB physical)"
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
