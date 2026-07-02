import Chau7Core
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
        parts.append(DateFormatters.iso8601.string(from: timestamp))

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
}

// MARK: - Performance Tracker

/// Current process memory usage (mach resident size).
enum PerfTracker {
    /// Get current memory usage in MB
    static func currentMemoryMB() -> Double? {
        ProcessMemory.residentBytes().map { Double($0) / 1024 / 1024 }
    }
}

// MARK: - Enhanced Logger

/// Enhanced logging with categories, correlation, and structured output
enum LogEnhanced {

    // MARK: - Configuration

    private static let enabledCategories: Set<LogCategory> = Set(LogCategory.allCases)
    private static var osLogs: [LogCategory: OSLog] = [:]

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
            correlationId: correlationId,
            metadata: metadata,
            file: file,
            function: function,
            line: line,
            duration: duration,
            memoryMB: memoryMB
        )

        // Output to appropriate destinations
        let text = entry.formattedText
        Log.sink?(text)
        if Log.isVerbose {
            print(text) // swiftlint:disable:this no_print_statements
        }
        Log.writeRaw(text)

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

// Note: live memory-pressure handling is in MemoryPressureResponder +
// MemoryPressureCoordinator (Performance/). The previous never-started
// MemoryPressureMonitor here was dead code and has been removed.
