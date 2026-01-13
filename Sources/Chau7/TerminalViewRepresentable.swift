import SwiftUI
import AppKit
import SwiftTerm
import QuartzCore

struct TerminalViewRepresentable: NSViewRepresentable {
    @ObservedObject var model: TerminalSessionModel
    var isSuspended: Bool
    var isActive: Bool
    @ObservedObject private var settings = FeatureSettings.shared

    func makeNSView(context: Context) -> Chau7TerminalView {
        // Reuse existing terminal view if available (preserves shell session across SwiftUI view recreations)
        if let existingView = model.existingTerminalView {
            Log.trace("Reusing existing terminal view for session")
            existingView.notifyUpdateChanges = !isSuspended
            existingView.isHidden = isSuspended
            existingView.setEventMonitoringEnabled(isActive && !isSuspended)
            return existingView
        }

        // Create new terminal view and start shell process
        let view = Chau7TerminalView(frame: .zero)

        // CRITICAL: Disable Big Sur's full-redraw behavior.
        // Starting with Big Sur, macOS redraws the ENTIRE view even when only
        // a small region is marked dirty. This adds significant latency.
        // Setting this to true enables incremental/partial redraws.
        view.disableFullRedrawOnAnyChanges = true

        view.processDelegate = model
        view.font = terminalFont()
        view.applyColorScheme(settings.currentColorScheme)
        view.applyCursorStyle(style: settings.cursorStyle, blink: settings.cursorBlink)
        view.applyBellSettings(enabled: settings.bellEnabled, sound: settings.bellSound)
        view.applyScrollbackLines(settings.scrollbackLines)
        view.notifyUpdateChanges = !isSuspended
        view.isHidden = isSuspended
        view.setEventMonitoringEnabled(isActive && !isSuspended)
        view.allowMouseReporting = false
        view.onInput = { [weak model] text in
            model?.handleInput(text)
        }
        view.onOutput = { [weak model] data in
            model?.handleOutput(data)
        }
        view.onBufferChanged = { [weak model] in
            model?.scheduleSearchRefresh()
            model?.highlightView?.scheduleDisplay()  // Use batched display for better latency
        }

        // MARK: - Disable Implicit Animations (Latency Optimization)
        // Implicit CALayer animations can add 250ms+ to rendering. Disable them
        // for all terminal-related views to ensure immediate display updates.
        view.wantsLayer = true
        view.layer?.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]

        let cursorLineView = TerminalCursorLineView(frame: .zero)
        cursorLineView.autoresizingMask = [.width, .height]
        cursorLineView.wantsLayer = true
        cursorLineView.layer?.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "opacity": NSNull()]
        view.addSubview(cursorLineView)
        view.attachCursorLineView(cursorLineView)

        let highlightView = TerminalHighlightView(frame: .zero)
        highlightView.terminalView = view
        highlightView.session = model
        highlightView.autoresizingMask = [.width, .height]
        highlightView.wantsLayer = true
        highlightView.layer?.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        highlightView.layer?.backgroundColor = NSColor.clear.cgColor
        view.addSubview(highlightView)
        highlightView.frame = view.bounds
        model.attachHighlightView(highlightView)

        // Show a random power user tip while the shell is starting
        let tip = PowerUserTips.randomFormattedTip()
        view.feed(text: "\(tip)\r\n")

        let shell = model.defaultShell()
        let execName = "-" + URL(fileURLWithPath: shell).lastPathComponent
        let env = model.buildEnvironment()
        // Note: Do NOT change process-wide CWD here - it affects all tabs.
        // The shell process starts with its own CWD from the environment.
        let args = model.shellArguments()
        view.startProcess(executable: shell, args: args, environment: env, execName: execName)

        model.attachTerminal(view)
        model.applyFontSize()

        // Apply shell integration after shell is ready.
        // We detect readiness by watching for the first output (prompt).
        model.scheduleShellIntegration(for: view)
        return view
    }

    func updateNSView(_ nsView: Chau7TerminalView, context: Context) {
        nsView.setEventMonitoringEnabled(isActive && !isSuspended)
        if nsView.isHidden != isSuspended {
            nsView.isHidden = isSuspended
            if !isSuspended {
                nsView.needsDisplay = true
            }
        }
        if nsView.notifyUpdateChanges == isSuspended {
            nsView.notifyUpdateChanges = !isSuspended
        }
        let isCodex = model.activeAppName == "Codex"
        nsView.setCursorLineHighlightEnabled(isCodex)
        nsView.configureCursorLineHighlight(contextLines: isCodex, inputHistory: isCodex)

        let desiredFont = terminalFont()
        if nsView.font.fontName != desiredFont.fontName || nsView.font.pointSize != desiredFont.pointSize {
            nsView.font = desiredFont
        }
        nsView.applyColorScheme(settings.currentColorScheme)
        nsView.applyCursorStyle(style: settings.cursorStyle, blink: settings.cursorBlink)
        nsView.applyBellSettings(enabled: settings.bellEnabled, sound: settings.bellSound)
        nsView.applyScrollbackLines(settings.scrollbackLines)
    }

    private func terminalFont() -> NSFont {
        if let font = NSFont(name: settings.fontFamily, size: model.fontSize) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: model.fontSize, weight: .regular)
    }
}
