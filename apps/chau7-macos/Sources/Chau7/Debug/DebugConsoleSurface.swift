import AppKit
import SwiftUI

enum DebugConsoleSurface: String, CaseIterable, Hashable, Identifiable {
    case all
    case diagnostics
    case runtimeInspector
    case usageMonitor

    var id: String {
        rawValue
    }

    var tabs: [DebugConsoleTab] {
        switch self {
        case .all:
            return DebugConsoleTab.allCases
        case .diagnostics:
            return [.health, .logs, .performance, .lag]
        case .runtimeInspector:
            return [.state, .events, .report]
        case .usageMonitor:
            return [.usage, .analytics, .repos, .tokenOptimizer]
        }
    }

    var defaultTab: DebugConsoleTab {
        switch self {
        case .all:
            return .health
        case .diagnostics:
            return .health
        case .runtimeInspector:
            return .state
        case .usageMonitor:
            return .usage
        }
    }

    var title: String {
        switch self {
        case .all:
            return L("debug.surface.all.title", "Debug Console")
        case .diagnostics:
            return L("debug.surface.diagnostics.title", "Diagnostics")
        case .runtimeInspector:
            return L("debug.surface.runtime.title", "Runtime Inspector")
        case .usageMonitor:
            return L("debug.surface.usage.title", "Usage Monitor")
        }
    }

    var subtitle: String {
        switch self {
        case .all:
            return L("debug.surface.all.subtitle", "All diagnostic surfaces")
        case .diagnostics:
            return L("debug.surface.diagnostics.subtitle", "Health, logs, lag, and performance")
        case .runtimeInspector:
            return L("debug.surface.runtime.subtitle", "Tabs, sessions, events, and snapshots")
        case .usageMonitor:
            return L("debug.surface.usage.subtitle", "AI usage, cost, quota, and repositories")
        }
    }

    var icon: String {
        switch self {
        case .all:
            return "ladybug.fill"
        case .diagnostics:
            return "stethoscope"
        case .runtimeInspector:
            return "scope"
        case .usageMonitor:
            return "chart.line.uptrend.xyaxis"
        }
    }

    var tint: Color {
        switch self {
        case .all:
            return .orange
        case .diagnostics:
            return .green
        case .runtimeInspector:
            return .blue
        case .usageMonitor:
            return .purple
        }
    }

    var windowTitle: String {
        switch self {
        case .all:
            return L("window.debugConsole", "Chau7 Debug Console")
        case .diagnostics:
            return L("window.diagnostics", "Chau7 Diagnostics")
        case .runtimeInspector:
            return L("window.runtimeInspector", "Chau7 Runtime Inspector")
        case .usageMonitor:
            return L("window.usageMonitor", "Chau7 Usage Monitor")
        }
    }

    var initialSize: NSSize {
        switch self {
        case .all:
            return NSSize(width: 900, height: 620)
        case .diagnostics, .runtimeInspector, .usageMonitor:
            return NSSize(width: 840, height: 580)
        }
    }
}

enum DebugConsoleTab: String, CaseIterable, Hashable, Identifiable {
    case state
    case tokenOptimizer
    case events
    case lag
    case performance
    case logs
    case report
    case analytics
    case health
    case repos
    case usage

    enum Section: String, CaseIterable, Hashable, Identifiable {
        case operate
        case inspect
        case observe
        case account

        var id: String {
            rawValue
        }

        var title: String {
            switch self {
            case .operate:
                return L("debug.nav.operate", "Operate")
            case .inspect:
                return L("debug.nav.inspect", "Inspect")
            case .observe:
                return L("debug.nav.observe", "Observe")
            case .account:
                return L("debug.nav.account", "Account")
            }
        }
    }

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .state:
            return L("State", "State")
        case .tokenOptimizer:
            return L("debug.optimizer", "Token Optimizer")
        case .events:
            return L("Events", "Events")
        case .lag:
            return L("Lag", "Lag")
        case .performance:
            return L("debug.perfTab", "Perf")
        case .logs:
            return L("Logs", "Logs")
        case .report:
            return L("Report", "Report")
        case .analytics:
            return L("debug.analytics", "Analytics")
        case .health:
            return L("debug.health", "Health")
        case .repos:
            return L("debug.repos", "Repos")
        case .usage:
            return L("debug.usage", "Usage")
        }
    }

    var icon: String {
        switch self {
        case .state:
            return "switch.2"
        case .tokenOptimizer:
            return "wand.and.stars"
        case .events:
            return "timeline.selection"
        case .lag:
            return "speedometer"
        case .performance:
            return "gauge.with.dots.needle.bottom.50percent"
        case .logs:
            return "doc.text.magnifyingglass"
        case .report:
            return "square.and.arrow.up"
        case .analytics:
            return "chart.bar.xaxis"
        case .health:
            return "heart.text.square"
        case .repos:
            return "folder"
        case .usage:
            return "gauge.open.with.lines.needle.33percent"
        }
    }

    var section: Section {
        switch self {
        case .health, .logs:
            return .operate
        case .state, .events, .report:
            return .inspect
        case .lag, .performance:
            return .observe
        case .usage, .analytics, .repos, .tokenOptimizer:
            return .account
        }
    }
}
