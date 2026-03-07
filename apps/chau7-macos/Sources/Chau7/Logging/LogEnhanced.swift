import Foundation
import os.log

// MARK: - Log Categories (Subsystems)

/// Categories for filtering logs by component
enum LogCategory: String, CaseIterable {
    case app = "App"
    case tabs = "Tabs"
    case terminal = "Terminal"
    case render = "Render"
    case input = "Input"
    case notifications = "Notifications"
    case snippets = "Snippets"
    case network = "Network"
    case performance = "Perf"
    case memory = "Memory"
    case recovery = "Recovery"
    case cto = "CTO"

    var emoji: String {
        switch self {
        case .app: return "📱"
        case .tabs: return "📑"
        case .terminal: return "💻"
        case .render: return "🎨"
        case .input: return "⌨️"
        case .notifications: return "🔔"
        case .snippets: return "📝"
        case .network: return "🌐"
        case .performance: return "⚡"
        case .memory: return "🧠"
        case .recovery: return "🔧"
        case .cto: return "🧩"
        }
    }

    var osLogCategory: String {
        rawValue.lowercased()
    }
}

// MARK: - Structured Log Entry

/// A structured log entry with rich metadata
struct LogEntry: Codable {
    let timestamp: Date
    let level: String
    let category: String
    let message: String
    let correlationId: String?
    let metadata: [String: String]?
    let file: String?
    let function: String?
    let line: Int?
    let duration: Double? // For performance tracking
    let memoryMB: Double? // Memory at log time

    var formattedText: String {
        var parts: [String] = []

        // Timestamp
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        parts.append(formatter.string(from: timestamp))

        // Level + Category
        parts.append("[\(level)][\(category)]")

        // Correlation ID if present
        if let cid = correlationId {
            parts.append("[\(cid.prefix(8))]")
        }

        // Message
        parts.append(message)

        // Duration if present
        if let dur = duration {
            parts.append("(\(String(format: "%.2fms", dur * 1000)))")
        }

        // Memory if present
        if let mem = memoryMB {
            parts.append("[mem:\(String(format: "%.1f", mem))MB]")
        }

        // Metadata if present
        if let meta = metadata, !meta.isEmpty {
            let metaStr = meta.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            parts.append("{\(metaStr)}")
        }

        // Source location for trace/error
        if level == "TRACE" || level == "ERROR", let file = file, let fn = function, let ln = line {
            let filename = (file as NSString).lastPathComponent
            parts.append("@\(filename):\(ln) \(fn)")
        }

        return parts.joined(separator: " ")
    }

    var jsonString: String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Correlation Context

/// Tracks correlation IDs for async operation tracing
final class LogCorrelation {
    static let shared = LogCorrelation()

    private let queue = DispatchQueue(label: "com.chau7.log.correlation")
    private var currentId: String?
    private var operationStack: [String] = []

    private init() {}

    /// Current correlation ID (thread-local would be better, but this works for main thread)
    var current: String? {
        queue.sync { currentId }
    }

    /// Start a new correlated operation
    func begin(_ operation: String) -> String {
        let id = UUID().uuidString.prefix(8).lowercased()
        queue.sync {
            operationStack.append(operation)
            currentId = String(id)
        }
        return String(id)
    }

    /// End the current operation
    func end() {
        queue.sync {
            _ = operationStack.popLast()
            currentId = operationStack.isEmpty ? nil : currentId
        }
    }

    /// Execute a block with correlation tracking
    func scoped<T>(_ operation: String, _ block: () throws -> T) rethrows -> T {
        let id = begin(operation)
        defer { end() }
        LogEnhanced.trace(.app, "Begin: \(operation)", correlationId: id)
        let result = try block()
        LogEnhanced.trace(.app, "End: \(operation)", correlationId: id)
        return result
    }
}

// MARK: - Performance Tracker

/// Tracks operation duration for performance logging
final class PerfTracker {
    let operation: String
    let category: LogCategory
    let correlationId: String?
    let startTime: CFAbsoluteTime
    let startMemory: Double?
    private var metadata: [String: String] = [:]

    init(_ operation: String, category: LogCategory = .performance, correlationId: String? = nil) {
        self.operation = operation
        self.category = category
        self.correlationId = correlationId ?? LogCorrelation.shared.current
        self.startTime = CFAbsoluteTimeGetCurrent()
        self.startMemory = PerfTracker.currentMemoryMB()
    }

    /// Add metadata to the performance log
    func add(_ key: String, _ value: String) {
        metadata[key] = value
    }

    /// End tracking and log the result
    func end(threshold: Double = 0) {
        let duration = CFAbsoluteTimeGetCurrent() - startTime
        guard duration >= threshold else { return }

        let endMemory = PerfTracker.currentMemoryMB()
        var meta = metadata

        if let start = startMemory, let end = endMemory {
            let delta = end - start
            if abs(delta) > 1.0 {
                meta["memDelta"] = String(format: "%.1fMB", delta)
            }
        }

        LogEnhanced.log(
            level: duration > 0.1 ? "WARN" : "TRACE",
            category: category,
            message: operation,
            correlationId: correlationId,
            metadata: meta.isEmpty ? nil : meta,
            duration: duration,
            memoryMB: endMemory
        )
    }

    /// Convenience for scoped tracking
    static func measure<T>(_ operation: String, category: LogCategory = .performance, _ block: () throws -> T) rethrows -> T {
        let tracker = PerfTracker(operation, category: category)
        defer { tracker.end() }
        return try block()
    }

    /// Get current memory usage in MB
    static func currentMemoryMB() -> Double? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.resident_size) / 1024 / 1024
    }
}

// MARK: - Enhanced Logger

/// Enhanced logging with categories, correlation, and structured output
enum LogEnhanced {

    // MARK: - Configuration

    private static var enabledCategories: Set<LogCategory> = Set(LogCategory.allCases)
    private static var isStructuredOutput = false
    private static var osLogs: [LogCategory: OSLog] = [:]

    /// Configure which categories are enabled
    static func setEnabledCategories(_ categories: Set<LogCategory>) {
        enabledCategories = categories
    }

    /// Enable structured JSON output
    static func enableStructuredOutput(_ enabled: Bool) {
        isStructuredOutput = enabled
    }

    // MARK: - Logging Methods

    static func info(
        _ category: LogCategory,
        _ message: String,
        metadata: [String: String]? = nil,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log(
            level: "INFO",
            category: category,
            message: message,
            metadata: metadata,
            file: file,
            function: function,
            line: line
        )
    }

    static func warn(
        _ category: LogCategory,
        _ message: String,
        metadata: [String: String]? = nil,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log(
            level: "WARN",
            category: category,
            message: message,
            metadata: metadata,
            file: file,
            function: function,
            line: line
        )
    }

    static func error(
        _ category: LogCategory,
        _ message: String,
        metadata: [String: String]? = nil,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log(
            level: "ERROR",
            category: category,
            message: message,
            metadata: metadata,
            file: file,
            function: function,
            line: line
        )
    }

    static func trace(
        _ category: LogCategory,
        _ message: String,
        correlationId: String? = nil,
        metadata: [String: String]? = nil,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        guard Log.isTraceEnabled else { return }
        log(
            level: "TRACE",
            category: category,
            message: message,
            correlationId: correlationId,
            metadata: metadata,
            file: file,
            function: function,
            line: line
        )
    }

    // MARK: - Core Logging

    static func log(
        level: String,
        category: LogCategory,
        message: String,
        correlationId: String? = nil,
        metadata: [String: String]? = nil,
        file: String? = nil,
        function: String? = nil,
        line: Int? = nil,
        duration: Double? = nil,
        memoryMB: Double? = nil
    ) {

        guard enabledCategories.contains(category) else { return }

        let entry = LogEntry(
            timestamp: Date(),
            level: level,
            category: category.rawValue,
            message: message,
            correlationId: correlationId ?? LogCorrelation.shared.current,
            metadata: metadata,
            file: file,
            function: function,
            line: line,
            duration: duration,
            memoryMB: memoryMB
        )

        // Output to appropriate destinations
        if isStructuredOutput, let json = entry.jsonString {
            Log.sink?(json)
            if Log.isVerbose {
                print(json) // swiftlint:disable:this no_print_statements
            }
            Log.writeRaw(json)
        } else {
            let text = entry.formattedText
            Log.sink?(text)
            if Log.isVerbose {
                print(text) // swiftlint:disable:this no_print_statements
            }

            // Also write to file as plain text
            Log.writeRaw(text)
        }

        // Also log to OSLog for Console.app integration
        logToOSLog(entry, category: category)
    }

    private static func logToOSLog(_ entry: LogEntry, category: LogCategory) {
        let osLog = osLogs[category] ?? {
            let log = OSLog(subsystem: "com.chau7", category: category.osLogCategory)
            osLogs[category] = log
            return log
        }()

        let type: OSLogType
        switch entry.level {
        case "ERROR": type = .error
        case "WARN": type = .default
        case "TRACE": type = .debug
        default: type = .info
        }

        os_log("%{public}@", log: osLog, type: type, entry.message)
    }

    // MARK: - State Snapshot (for debugging)

    /// Capture current app state for debugging
    static func captureStateSnapshot(reason: String, tabsModel: Any? = nil) -> [String: String] {
        var state: [String: String] = [
            "reason": reason,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]

        // Memory
        if let mem = PerfTracker.measure("memory check", category: .memory, { PerfTracker.currentMemoryMB() }) {
            state["memoryMB"] = String(format: "%.1f", mem)
        }

        // Thread info
        state["isMainThread"] = Thread.isMainThread ? "yes" : "no"
        state["threadName"] = Thread.current.name ?? "unknown"

        // Add tabs info if available (would need to cast properly)
        // This is a placeholder - in real implementation, pass the actual model

        return state
    }
}

// MARK: - Convenience Extensions

extension LogEnhanced {
    /// Log tab-related operations with consistent format
    static func tab(
        _ message: String,
        tabId: UUID? = nil,
        tabCount: Int? = nil,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        var meta: [String: String] = [:]
        if let id = tabId { meta["tabId"] = id.uuidString.prefix(8).lowercased() }
        if let count = tabCount { meta["count"] = String(count) }
        trace(.tabs, message, metadata: meta.isEmpty ? nil : meta, file: file, function: function, line: line)
    }

    /// Log render-related operations
    static func render(
        _ message: String,
        viewName: String? = nil,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        var meta: [String: String] = [:]
        if let name = viewName { meta["view"] = name }
        trace(.render, message, metadata: meta.isEmpty ? nil : meta, file: file, function: function, line: line)
    }

    /// Log recovery operations
    static func recovery(
        _ message: String,
        metadata: [String: String]? = nil,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        warn(.recovery, message, metadata: metadata, file: file, function: function, line: line)
    }
}

// MARK: - Memory Pressure Monitoring

final class MemoryPressureMonitor {
    static let shared = MemoryPressureMonitor()

    private var source: DispatchSourceMemoryPressure?

    private init() {}

    func start() {
        source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source?.setEventHandler { [weak self] in
            self?.handleMemoryPressure()
        }
        source?.resume()
        LogEnhanced.info(.memory, "Memory pressure monitoring started")
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func handleMemoryPressure() {
        guard let source = source else { return }
        let event = source.data

        let state = LogEnhanced.captureStateSnapshot(reason: "memory_pressure")

        if event.contains(.critical) {
            LogEnhanced.error(.memory, "CRITICAL memory pressure", metadata: state)
        } else if event.contains(.warning) {
            LogEnhanced.warn(.memory, "Memory pressure warning", metadata: state)
        }
    }
}
