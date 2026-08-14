import AppKit
import Foundation

/// On-demand per-tab memory attribution — the verification instrument for the
/// memory-reduction program. Every input is an O(1) accessor (counts and
/// capacities, never buffer walks), and nothing here runs on a timer: the
/// DebugConsole Memory tab and `TerminalDiagnostics` assemble a report only
/// when asked.
struct TerminalMemoryReport {
    struct TabEntry: Identifiable {
        let id: String
        let title: String
        let renderPhase: String
        let isTUIProtected: Bool
        let alternateScreenActive: Bool
        let historyRows: Int
        /// Rust ring estimate (history + screen + alt screen cells).
        let estimatedRingBytes: Int
        /// `session.cachedBufferData` — full-buffer copy retained for search.
        let sessionCachedBufferBytes: Int
        let sessionCachedRemoteTextBytes: Int
        let restorationCacheBytes: Int
        let cachedBufferLineCount: Int
        /// `previousGrid` diff baseline + CPU-fallback `RustGridView` copy.
        let cpuFallbackBytes: Int

        var totalBytes: Int {
            estimatedRingBytes + sessionCachedBufferBytes + sessionCachedRemoteTextBytes
                + restorationCacheBytes + cpuFallbackBytes
        }
    }

    /// Per-window renderer attribution (Metal resources are per window, not
    /// per tab — hidden tabs hold none).
    struct RendererEntry {
        let gridCols: Int
        let gridRows: Int
        let instanceBufferBytes: Int
        let atlasTextureBytes: Int
        let atlasContextBytes: Int
        let tripleBufferBytes: Int
        let glyphCacheEntries: Int

        var totalBytes: Int {
            instanceBufferBytes + atlasTextureBytes + atlasContextBytes + tripleBufferBytes
        }
    }

    let capturedAt: Date
    /// Sorted by `totalBytes`, largest first.
    let tabs: [TabEntry]
    let renderer: RendererEntry?
    let processFootprintMB: Double?

    var totalTabBytes: Int {
        tabs.reduce(0) { $0 + $1.totalBytes }
    }

    @MainActor
    static func capture(overlayModel: OverlayTabsModel) -> TerminalMemoryReport {
        var entries: [TabEntry] = []
        for tab in overlayModel.tabs {
            for session in tab.splitController.root.allSessions {
                let view = session.activeTerminalView as? RustTerminalView
                let stats = view?.rustTerminal?.memoryStats()
                entries.append(TabEntry(
                    id: session.tabIdentifier,
                    title: tab.customTitle ?? session.title,
                    renderPhase: view?.currentRenderPhase.rawValue ?? "detached",
                    isTUIProtected: session.shouldProtectTerminalUIState,
                    alternateScreenActive: stats?.alternateScreenActive ?? false,
                    historyRows: stats?.historyRows ?? 0,
                    estimatedRingBytes: stats?.estimatedGridBytes ?? 0,
                    sessionCachedBufferBytes: session.cachedBufferData?.count ?? 0,
                    sessionCachedRemoteTextBytes: session.cachedRemoteOutputText.utf8.count,
                    restorationCacheBytes: session.cachedRestorationScrollback?.content?.utf8.count ?? 0,
                    cachedBufferLineCount: view?.cachedBufferLines?.count ?? 0,
                    cpuFallbackBytes: view?.estimatedCPUFallbackBytes ?? 0
                ))
            }
        }
        entries.sort { $0.totalBytes > $1.totalBytes }

        let renderer = overlayModel.sharedMetalCoordinator.map { coordinator -> RendererEntry in
            let footprint = coordinator.memoryFootprint
            return RendererEntry(
                gridCols: footprint.gridCols,
                gridRows: footprint.gridRows,
                instanceBufferBytes: footprint.rendererFootprint.instanceBufferBytes,
                atlasTextureBytes: footprint.rendererFootprint.atlasTextureBytes,
                atlasContextBytes: footprint.rendererFootprint.atlasContextBytes,
                tripleBufferBytes: footprint.tripleBufferBytes,
                glyphCacheEntries: footprint.rendererFootprint.glyphCacheEntries
            )
        }

        return TerminalMemoryReport(
            capturedAt: Date(),
            tabs: entries,
            renderer: renderer,
            processFootprintMB: PerfTracker.currentMemoryMB()
        )
    }

    /// Plain-text table for the DebugConsole Memory tab and the
    /// `TerminalDiagnostics` dump.
    func formatted() -> String {
        var lines: [String] = []
        if let processFootprintMB {
            lines.append(String(format: "process footprint: %.1f MB", processFootprintMB))
        }
        lines.append("attributed tab total: \(Self.formatBytes(totalTabBytes)) across \(tabs.count) pane(s)")
        lines.append("")
        lines.append([
            pad("phase", 9), pad("flags", 14), pad("history", 8),
            pad("ring", 10), pad("srchCache", 10), pad("restCache", 10),
            pad("cpuCopy", 10), "title"
        ].joined(separator: " "))
        for tab in tabs {
            var flags: [String] = []
            if tab.isTUIProtected { flags.append("tui") }
            if tab.alternateScreenActive { flags.append("alt") }
            if tab.cachedBufferLineCount > 0 { flags.append("lines:\(tab.cachedBufferLineCount)") }
            lines.append([
                pad(tab.renderPhase, 9),
                pad(flags.joined(separator: ","), 14),
                pad("\(tab.historyRows)", 8),
                pad(Self.formatBytes(tab.estimatedRingBytes), 10),
                pad(Self.formatBytes(tab.sessionCachedBufferBytes + tab.sessionCachedRemoteTextBytes), 10),
                pad(Self.formatBytes(tab.restorationCacheBytes), 10),
                pad(Self.formatBytes(tab.cpuFallbackBytes), 10),
                tab.title
            ].joined(separator: " "))
        }
        if let renderer {
            lines.append("")
            lines.append("renderer (per window, grid \(renderer.gridCols)x\(renderer.gridRows)):")
            lines.append("  instance buffer: \(Self.formatBytes(renderer.instanceBufferBytes))")
            lines.append("  glyph atlas texture: \(Self.formatBytes(renderer.atlasTextureBytes))")
            lines.append("  glyph atlas CGContext: \(Self.formatBytes(renderer.atlasContextBytes))")
            lines.append("  triple buffer: \(Self.formatBytes(renderer.tripleBufferBytes))")
            lines.append("  glyph cache entries: \(renderer.glyphCacheEntries)")
            lines.append("  renderer total: \(Self.formatBytes(renderer.totalBytes))")
        }
        return lines.joined(separator: "\n")
    }

    private func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    static func formatBytes(_ bytes: Int) -> String {
        switch bytes {
        case ..<1024:
            return "\(bytes)B"
        case ..<(1024 * 1024):
            return String(format: "%.1fKB", Double(bytes) / 1024)
        case ..<(1024 * 1024 * 1024):
            return String(format: "%.1fMB", Double(bytes) / (1024 * 1024))
        default:
            return String(format: "%.2fGB", Double(bytes) / (1024 * 1024 * 1024))
        }
    }
}
