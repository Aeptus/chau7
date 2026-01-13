// MARK: - Thread Priority and QoS Tuning
// Configures thread priorities for optimal latency in render and input paths.

import Foundation
import Darwin

// MARK: - Mach Thread Policy Constants
// These constants are defined in mach/thread_policy.h but not exposed to Swift

private let THREAD_EXTENDED_POLICY_COUNT = mach_msg_type_number_t(
    MemoryLayout<thread_extended_policy_data_t>.size / MemoryLayout<integer_t>.size
)

private let THREAD_PRECEDENCE_POLICY_COUNT = mach_msg_type_number_t(
    MemoryLayout<thread_precedence_policy_data_t>.size / MemoryLayout<integer_t>.size
)

private let THREAD_TIME_CONSTRAINT_POLICY_COUNT = mach_msg_type_number_t(
    MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size
)

/// Thread priority management for low-latency terminal rendering.
public enum ThreadPriority {

    // MARK: - Thread Priority Configuration

    /// Sets the current thread to real-time priority.
    /// Use for render thread to ensure consistent frame timing.
    public static func setRealTimePriority() -> Bool {
        let thread = mach_thread_self()

        // Disable time-sharing (prevents preemption)
        var extendedPolicy = thread_extended_policy_data_t(timeshare: 0)
        var result = thread_policy_set(
            thread,
            thread_policy_flavor_t(THREAD_EXTENDED_POLICY),
            withUnsafeMutablePointer(to: &extendedPolicy) {
                $0.withMemoryRebound(to: integer_t.self, capacity: 1) { $0 }
            },
            mach_msg_type_number_t(THREAD_EXTENDED_POLICY_COUNT)
        )

        guard result == KERN_SUCCESS else {
            Log.warn("ThreadPriority: Failed to disable time-sharing: \(result)")
            return false
        }

        // Set high thread precedence (0-63, higher = more priority)
        var precedencePolicy = thread_precedence_policy_data_t(importance: 63)
        result = thread_policy_set(
            thread,
            thread_policy_flavor_t(THREAD_PRECEDENCE_POLICY),
            withUnsafeMutablePointer(to: &precedencePolicy) {
                $0.withMemoryRebound(to: integer_t.self, capacity: 1) { $0 }
            },
            mach_msg_type_number_t(THREAD_PRECEDENCE_POLICY_COUNT)
        )

        guard result == KERN_SUCCESS else {
            Log.warn("ThreadPriority: Failed to set thread precedence: \(result)")
            return false
        }

        Log.info("ThreadPriority: Set real-time priority on thread")
        return true
    }

    /// Sets real-time scheduling constraints for time-critical work.
    /// - Parameters:
    ///   - period: Expected period between callbacks (nanoseconds)
    ///   - computation: Expected computation time per period (nanoseconds)
    ///   - constraint: Maximum time for computation (nanoseconds)
    public static func setRealTimeConstraint(
        period: UInt32,
        computation: UInt32,
        constraint: UInt32
    ) -> Bool {
        let thread = mach_thread_self()

        var policy = thread_time_constraint_policy_data_t(
            period: period,
            computation: computation,
            constraint: constraint,
            preemptible: 0  // Non-preemptible
        )

        let result = thread_policy_set(
            thread,
            thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY),
            withUnsafeMutablePointer(to: &policy) {
                $0.withMemoryRebound(to: integer_t.self, capacity: 4) { $0 }
            },
            mach_msg_type_number_t(THREAD_TIME_CONSTRAINT_POLICY_COUNT)
        )

        guard result == KERN_SUCCESS else {
            Log.warn("ThreadPriority: Failed to set time constraint: \(result)")
            return false
        }

        Log.info("ThreadPriority: Set real-time constraint (period: \(period/1_000_000)ms)")
        return true
    }

    /// Resets thread to default scheduling.
    public static func resetToDefault() -> Bool {
        let thread = mach_thread_self()

        // Re-enable time-sharing
        var extendedPolicy = thread_extended_policy_data_t(timeshare: 1)
        let result = thread_policy_set(
            thread,
            thread_policy_flavor_t(THREAD_EXTENDED_POLICY),
            withUnsafeMutablePointer(to: &extendedPolicy) {
                $0.withMemoryRebound(to: integer_t.self, capacity: 1) { $0 }
            },
            mach_msg_type_number_t(THREAD_EXTENDED_POLICY_COUNT)
        )

        return result == KERN_SUCCESS
    }

    // MARK: - QoS Configuration

    /// QoS configurations for different terminal operations
    public enum TerminalQoS {
        /// For render thread - highest priority
        case render
        /// For PTY read thread - high priority
        case ptyRead
        /// For PTY write thread - high priority
        case ptyWrite
        /// For background parsing
        case parsing
        /// For search and other background work
        case background

        var dispatchQoS: DispatchQoS {
            switch self {
            case .render:
                return .userInteractive
            case .ptyRead, .ptyWrite:
                return .userInitiated
            case .parsing:
                return .userInitiated
            case .background:
                return .utility
            }
        }

        var qosClass: qos_class_t {
            switch self {
            case .render:
                return QOS_CLASS_USER_INTERACTIVE
            case .ptyRead, .ptyWrite:
                return QOS_CLASS_USER_INITIATED
            case .parsing:
                return QOS_CLASS_USER_INITIATED
            case .background:
                return QOS_CLASS_UTILITY
            }
        }
    }

    /// Creates a dispatch queue with appropriate QoS for terminal operations.
    public static func makeQueue(for qos: TerminalQoS, label: String) -> DispatchQueue {
        DispatchQueue(
            label: label,
            qos: qos.dispatchQoS,
            attributes: [],
            autoreleaseFrequency: .workItem
        )
    }

    /// Sets the QoS class for the current thread.
    public static func setQoS(_ qos: TerminalQoS) -> Bool {
        let result = pthread_set_qos_class_self_np(qos.qosClass, 0)
        return result == 0
    }

    // MARK: - CPU Affinity (Best Effort)

    /// Attempts to pin thread to performance cores (Apple Silicon).
    /// Note: macOS doesn't expose direct CPU affinity, this is a hint.
    public static func preferPerformanceCores() {
        // Set high QoS which hints the scheduler to use performance cores
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
    }

    /// Attempts to use efficiency cores for background work.
    public static func preferEfficiencyCores() {
        pthread_set_qos_class_self_np(QOS_CLASS_BACKGROUND, 0)
    }
}

// MARK: - Render Thread Configuration

/// Configures a dedicated render thread with optimal settings.
public final class RenderThread {
    private var thread: Thread?
    private let workQueue: DispatchQueue
    private var isRunning = false
    private var frameCallback: (() -> Void)?

    /// Target frame rate
    public var targetFPS: Int = 120

    /// Actual measured FPS
    public private(set) var measuredFPS: Double = 0

    private var lastFrameTime: CFAbsoluteTime = 0
    private var frameCount: Int = 0
    private var fpsUpdateTime: CFAbsoluteTime = 0

    public init() {
        self.workQueue = ThreadPriority.makeQueue(for: .render, label: "com.chau7.render")
    }

    /// Starts the render thread with the given frame callback.
    public func start(frameCallback: @escaping () -> Void) {
        guard !isRunning else { return }

        self.frameCallback = frameCallback
        isRunning = true

        // Create dedicated render thread
        thread = Thread { [weak self] in
            self?.renderLoop()
        }
        thread?.name = "Chau7.RenderThread"
        thread?.qualityOfService = .userInteractive
        thread?.start()
    }

    /// Stops the render thread.
    public func stop() {
        isRunning = false
        thread?.cancel()
        thread = nil
    }

    private func renderLoop() {
        // Set real-time priority
        ThreadPriority.setRealTimePriority()

        // Set time constraint for 120Hz
        let periodNs: UInt32 = 8_333_333  // 8.33ms for 120Hz
        let computationNs: UInt32 = 2_000_000  // 2ms max computation
        ThreadPriority.setRealTimeConstraint(
            period: periodNs,
            computation: computationNs,
            constraint: computationNs
        )

        lastFrameTime = CFAbsoluteTimeGetCurrent()
        fpsUpdateTime = lastFrameTime

        while isRunning && !Thread.current.isCancelled {
            let frameStart = CFAbsoluteTimeGetCurrent()
            let targetInterval = 1.0 / Double(targetFPS)

            // Execute frame callback
            frameCallback?()

            // Update FPS measurement
            frameCount += 1
            let now = CFAbsoluteTimeGetCurrent()
            if now - fpsUpdateTime >= 1.0 {
                measuredFPS = Double(frameCount) / (now - fpsUpdateTime)
                frameCount = 0
                fpsUpdateTime = now
            }

            // Sleep until next frame
            let elapsed = CFAbsoluteTimeGetCurrent() - frameStart
            let sleepTime = max(0, targetInterval - elapsed)
            if sleepTime > 0 {
                Thread.sleep(forTimeInterval: sleepTime)
            }

            lastFrameTime = CFAbsoluteTimeGetCurrent()
        }

        // Reset priority before exiting
        ThreadPriority.resetToDefault()
    }
}

// MARK: - PTY Thread Configuration

/// Configures PTY read/write threads with optimal settings.
public final class PTYThreadManager {
    private let readQueue: DispatchQueue
    private let writeQueue: DispatchQueue

    public init() {
        self.readQueue = ThreadPriority.makeQueue(for: .ptyRead, label: "com.chau7.pty.read")
        self.writeQueue = ThreadPriority.makeQueue(for: .ptyWrite, label: "com.chau7.pty.write")
    }

    /// Executes a read operation on the optimized PTY read queue.
    public func read(_ work: @escaping () -> Void) {
        readQueue.async {
            ThreadPriority.setQoS(.ptyRead)
            work()
        }
    }

    /// Executes a write operation on the optimized PTY write queue.
    public func write(_ work: @escaping () -> Void) {
        writeQueue.async {
            ThreadPriority.setQoS(.ptyWrite)
            work()
        }
    }
}
