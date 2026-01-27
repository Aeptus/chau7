import SwiftUI
import AppKit
import SwiftTerm
import QuartzCore

/// Container view for the terminal (no inset needed - content is below toolbar)
final class TerminalContainerView: NSView {
    let terminalView: Chau7TerminalView
    var onFirstLayout: ((Chau7TerminalView) -> Void)?
    private var didRunFirstLayout = false

    init(terminalView: Chau7TerminalView) {
        self.terminalView = terminalView
        super.init(frame: .zero)
        addSubview(terminalView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func layout() {
        super.layout()
        terminalView.frame = bounds
        if !didRunFirstLayout && bounds.width > 0 && bounds.height > 0 {
            didRunFirstLayout = true
            onFirstLayout?(terminalView)
        }
    }
}

struct TerminalViewRepresentable: NSViewRepresentable {
    @ObservedObject var model: TerminalSessionModel
    var isSuspended: Bool
    var isActive: Bool
    var onFilePathClicked: ((String, Int?, Int?) -> Void)?  // F03: Internal editor callback
    @ObservedObject private var settings = FeatureSettings.shared

    func makeNSView(context: Context) -> TerminalContainerView {
        // Reuse existing terminal view if available (preserves shell session across SwiftUI view recreations)
        if let existingView = model.existingTerminalView {
            Log.trace("Reusing existing terminal view for session")
            existingView.notifyUpdateChanges = !isSuspended
            existingView.isHidden = isSuspended
            existingView.setEventMonitoringEnabled(isActive && !isSuspended)
            // Configure mouse reporting based on user setting.
            // When disabled (default), text selection always works.
            // When enabled, hold Shift to force text selection in apps like vim/tmux.
            existingView.allowMouseReporting = settings.isMouseReportingEnabled
            existingView.onFilePathClicked = onFilePathClicked  // F03: Update callback
            existingView.tabIdentifier = model.tabIdentifier
            existingView.isAtPrompt = { [weak model] in model?.isAtPrompt ?? false }
            existingView.installHistoryKeyMonitor()
            // Wrap in container if not already
            if let container = existingView.superview as? TerminalContainerView {
                return container
            }
            return TerminalContainerView(terminalView: existingView)
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
        // Configure mouse reporting based on user setting.
        // When disabled (default), text selection always works.
        // When enabled, hold Shift to force text selection in apps like vim/tmux.
        view.allowMouseReporting = settings.isMouseReportingEnabled
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
        view.onFilePathClicked = onFilePathClicked
        view.tabIdentifier = model.tabIdentifier
        view.isAtPrompt = { [weak model] in model?.isAtPrompt ?? false }
        view.installHistoryKeyMonitor()

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

        let container = TerminalContainerView(terminalView: view)
        container.onFirstLayout = { [weak model, weak view] terminalView in
            guard let model, let view else { return }
            // Show a random power user tip while the shell is starting
            let tip = PowerUserTips.randomFormattedTip()
            if let headerBox = terminalHeaderBox(cols: terminalView.getTerminal().cols, message: tip) {
                terminalView.feed(text: headerBox)
            }

            let shell = model.defaultShell()
            let execName = "-" + URL(fileURLWithPath: shell).lastPathComponent
            let env = model.buildEnvironment()
            // Note: Do NOT change process-wide CWD here - it affects all tabs.
            // The shell process starts with its own CWD from the environment.
            let args = model.shellArguments()
            terminalView.startProcess(executable: shell, args: args, environment: env, execName: execName)

            model.attachTerminal(view)
            model.applyFontSize()

            // Apply shell integration after shell is ready.
            // We detect readiness by watching for the first output (prompt).
            model.scheduleShellIntegration(for: view)
        }
        return container
    }

    func updateNSView(_ container: TerminalContainerView, context: Context) {
        let nsView = container.terminalView
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
        // Enable cursor line highlighting for any active AI agent (Claude, Codex, etc.)
        let isAIAgent = model.activeAppName != nil
        nsView.setCursorLineHighlightEnabled(isAIAgent)
        nsView.configureCursorLineHighlight(contextLines: isAIAgent, inputHistory: isAIAgent)

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

private func terminalHeaderBox(cols: Int, message: String) -> String? {
    let sideMargin = 2
    let boxWidth = cols - (sideMargin * 2)
    let interiorWidth = boxWidth - 2
    guard interiorWidth >= 4 else { return nil }
    let prefix = String(repeating: " ", count: sideMargin)
    let top = prefix + "+" + String(repeating: "-", count: interiorWidth) + "+"
    let sanitized = sanitizeBoxMessage(message)
    let fitMessage: String
    if sanitized.count > interiorWidth {
        let endIndex = sanitized.index(sanitized.startIndex, offsetBy: max(0, interiorWidth - 3))
        fitMessage = String(sanitized[..<endIndex]) + "..."
    } else {
        fitMessage = sanitized
    }
    let padding = max(0, interiorWidth - fitMessage.count)
    let leftPadding = padding / 2
    let rightPadding = padding - leftPadding
    let middle = prefix + "|" + String(repeating: " ", count: leftPadding) + fitMessage + String(repeating: " ", count: rightPadding) + "|"
    let bottom = prefix + "+" + String(repeating: "-", count: interiorWidth) + "+"
    let colorOn = "\u{1b}[97m"
    let colorOff = "\u{1b}[0m"
    return "\(colorOn)\(top)\r\n\(middle)\r\n\(bottom)\(colorOff)\r\n"
}

private func sanitizeBoxMessage(_ message: String) -> String {
    let replacements: [(String, String)] = [
        ("💡", "TIP"),
        ("⌘", "CMD+"),
        ("⇧", "SHIFT+"),
        ("⌥", "OPT+"),
        ("⌃", "CTRL+"),
        ("→", "->"),
        ("←", "<-"),
        ("↑", "^"),
        ("↓", "v"),
        ("•", "*")
    ]

    var working = message
    for (from, to) in replacements {
        working = working.replacingOccurrences(of: from, with: to)
    }

    var ascii = String()
    ascii.reserveCapacity(working.count)
    for scalar in working.unicodeScalars {
        if scalar.isASCII {
            ascii.unicodeScalars.append(scalar)
        } else {
            ascii.append(" ")
        }
    }

    let collapsed = ascii.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
}
