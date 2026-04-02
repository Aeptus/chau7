import Foundation
import Chau7Core

/// Emits app-level events for the notification system.
/// Handles: scheduled events, inactivity detection, memory threshold monitoring.
final class AppEventEmitter {
    private weak var appModel: AppModel?
    private var config: AppEventConfig {
        FeatureSettings.shared.appEventConfig
    }

    // Timers for different event types
    private var scheduledTimers: [String: DispatchSourceTimer] = [:]
    private var inactivityTimer: DispatchSourceTimer?
    private var memoryTimer: DispatchSourceTimer?

    // State tracking
    private var lastActivityTime = Date()
    private var hasEmittedInactivity = false
    private var lastMemoryWarningTime: Date?
    private var memoryHasDroppedBelowHysteresis = true // Start true so first alert fires

    private var configObserver: Any?

    init(appModel: AppModel?) {
        self.appModel = appModel
        setupTimers()
        observeConfigChanges()
    }

    // MARK: - Configuration

    private func observeConfigChanges() {
        // Observe changes to appEventConfig
        configObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Reconfigure timers when settings change
            self?.setupTimers()
        }
    }

    func setupTimers() {
        stopAllTimers()

        // Setup scheduled event timers
        for schedule in config.scheduledEvents where schedule.isEnabled {
            setupScheduledTimer(for: schedule)
        }

        // Setup inactivity timer if configured
        if config.inactivityThresholdMinutes > 0 {
            setupInactivityTimer()
        }

        // Setup memory monitoring if configured
        if config.memoryThresholdMB > 0 {
            setupMemoryTimer()
        }
    }

    // MARK: - Activity Tracking

    /// Call when user activity is detected (typing, command execution, etc.)
    func recordActivity() {
        lastActivityTime = Date()
        hasEmittedInactivity = false
    }

    // MARK: - Scheduled Events

    private func setupScheduledTimer(for schedule: ScheduledEvent) {
        let timer = DispatchSource.makeTimerSource(queue: .main)

        // Calculate initial fire time and repeating interval
        let (initialDelay, interval) = calculateSchedule(schedule)

        if let interval = interval {
            timer.schedule(deadline: .now() + initialDelay, repeating: interval)
        } else {
            timer.schedule(deadline: .now() + initialDelay)
        }

        timer.setEventHandler { [weak self] in
            self?.fireScheduledEvent(schedule)
        }

        timer.resume()
        scheduledTimers[schedule.id.uuidString] = timer
    }

    private func calculateSchedule(_ schedule: ScheduledEvent) -> (DispatchTimeInterval, DispatchTimeInterval?) {
        switch schedule.scheduleType {
        case .interval:
            let seconds = schedule.intervalMinutes * 60
            return (.seconds(seconds), .seconds(seconds))

        case .daily:
            // Calculate seconds until next occurrence of the daily time
            let calendar = Calendar.current
            let now = Date()
            let targetHour = calendar.component(.hour, from: schedule.dailyTime)
            let targetMinute = calendar.component(.minute, from: schedule.dailyTime)

            // Build today's target date
            var components = calendar.dateComponents([.year, .month, .day], from: now)
            components.hour = targetHour
            components.minute = targetMinute
            components.second = 0

            var nextFire: Date
            if let todayTarget = calendar.date(from: components) {
                if todayTarget > now {
                    // Today's target time is still in the future
                    nextFire = todayTarget
                } else {
                    // Today's time has passed, schedule for tomorrow
                    nextFire = calendar.date(byAdding: .day, value: 1, to: todayTarget) ?? todayTarget.addingTimeInterval(24 * 60 * 60)
                }
            } else {
                // Fallback: schedule for 24 hours from now
                nextFire = now.addingTimeInterval(24 * 60 * 60)
            }

            let initialDelay = max(1, Int(nextFire.timeIntervalSince(now)))
            return (.seconds(initialDelay), .seconds(24 * 60 * 60))

        case .hourly:
            // Fire at the specified minute of each hour
            let calendar = Calendar.current
            let now = Date()
            let currentMinute = calendar.component(.minute, from: now)
            var minutesToWait = schedule.hourlyMinute - currentMinute
            if minutesToWait <= 0 {
                minutesToWait += 60
            }
            return (.seconds(minutesToWait * 60), .seconds(60 * 60))
        }
    }

    private func fireScheduledEvent(_ schedule: ScheduledEvent) {
        // Re-check if schedule is still enabled (config may have changed)
        guard config.scheduledEvents.first(where: { $0.id == schedule.id })?.isEnabled == true else {
            return
        }

        emitEvent(
            type: "scheduled",
            message: schedule.name
        )
    }

    // MARK: - Inactivity Detection

    private func setupInactivityTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // Check every minute
        timer.schedule(deadline: .now() + .seconds(60), repeating: .seconds(60))
        timer.setEventHandler { [weak self] in
            self?.checkInactivity()
        }
        timer.resume()
        inactivityTimer = timer
    }

    private func checkInactivity() {
        guard !hasEmittedInactivity else { return }

        let thresholdSeconds = config.inactivityThresholdMinutes * 60
        let elapsed = Date().timeIntervalSince(lastActivityTime)

        if Int(elapsed) >= thresholdSeconds {
            hasEmittedInactivity = true
            let minutes = Int(elapsed / 60)
            emitEvent(
                type: "inactivity_timeout",
                message: "No activity for \(minutes) minutes"
            )
        }
    }

    // MARK: - Memory Monitoring

    private func setupMemoryTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // Check memory every 30 seconds
        timer.schedule(deadline: .now() + .seconds(30), repeating: .seconds(30), leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            self?.checkMemory()
        }
        timer.resume()
        memoryTimer = timer
    }

    private func checkMemory() {
        let memoryMB = getCurrentMemoryUsageMB()
        let threshold = config.memoryThresholdMB
        let hysteresis = config.memoryHysteresisMB

        // Check if memory has dropped below (threshold - hysteresis), which resets alert eligibility
        let hysteresisThreshold = max(0, threshold - hysteresis)
        if memoryMB < hysteresisThreshold {
            memoryHasDroppedBelowHysteresis = true
        }

        // Must be above threshold to alert
        guard memoryMB >= threshold else {
            return
        }

        // Must have dropped below hysteresis threshold since last alert
        guard memoryHasDroppedBelowHysteresis else {
            return
        }

        // Throttle memory warnings (max once per 5 minutes even with hysteresis)
        if let lastWarning = lastMemoryWarningTime {
            let timeSinceLastWarning = Date().timeIntervalSince(lastWarning)
            if timeSinceLastWarning < 300 { // 5 minutes
                return
            }
        }

        memoryHasDroppedBelowHysteresis = false
        lastMemoryWarningTime = Date()
        emitEvent(
            type: "memory_threshold",
            message: "Memory usage: \(memoryMB)MB (threshold: \(threshold)MB)"
        )
    }

    private func getCurrentMemoryUsageMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return 0
        }

        return Int(info.resident_size / 1024 / 1024)
    }

    // MARK: - Event Emission

    private func emitEvent(type: String, message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.appModel?.recordEvent(
                source: .app,
                type: type,
                tool: "App",
                message: message,
                notify: true
            )
        }
    }

    // MARK: - Cleanup

    private func stopAllTimers() {
        for (_, timer) in scheduledTimers {
            timer.cancel()
        }
        scheduledTimers.removeAll()

        inactivityTimer?.cancel()
        inactivityTimer = nil

        memoryTimer?.cancel()
        memoryTimer = nil
    }

    func cleanup() {
        stopAllTimers()
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
    }

    deinit {
        cleanup()
    }
}
