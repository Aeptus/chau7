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

/// Container view for the Rust terminal backend
final class RustTerminalContainerView: NSView {
    let terminalView: RustTerminalView
    var onFirstLayout: ((RustTerminalView) -> Void)?
    private var didRunFirstLayout = false

    init(terminalView: RustTerminalView) {
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

/// Unified container that holds either SwiftTerm or Rust terminal
final class UnifiedTerminalContainerView: NSView {
    private var swiftTermContainer: TerminalContainerView?
    private var rustContainer: RustTerminalContainerView?

    /// Whether this container uses the Rust backend
    let usesRustBackend: Bool

    init(swiftTermView: Chau7TerminalView) {
        self.usesRustBackend = false
        self.swiftTermContainer = TerminalContainerView(terminalView: swiftTermView)
        super.init(frame: .zero)
        addSubview(swiftTermContainer!)
    }

    init(rustView: RustTerminalView) {
        self.usesRustBackend = true
        self.rustContainer = RustTerminalContainerView(terminalView: rustView)
        super.init(frame: .zero)
        addSubview(rustContainer!)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func layout() {
        super.layout()
        swiftTermContainer?.frame = bounds
        rustContainer?.frame = bounds
    }

    var swiftTerminalView: Chau7TerminalView? {
        swiftTermContainer?.terminalView
    }

    var rustTerminalView: RustTerminalView? {
        rustContainer?.terminalView
    }

    var onFirstSwiftTermLayout: ((Chau7TerminalView) -> Void)? {
        get { swiftTermContainer?.onFirstLayout }
        set { swiftTermContainer?.onFirstLayout = newValue }
    }

    var onFirstRustLayout: ((RustTerminalView) -> Void)? {
        get { rustContainer?.onFirstLayout }
        set { rustContainer?.onFirstLayout = newValue }
    }
}

struct TerminalViewRepresentable: NSViewRepresentable {
    @ObservedObject var model: TerminalSessionModel
    var isSuspended: Bool
    var isActive: Bool
    var onFilePathClicked: ((String, Int?, Int?) -> Void)?  // F03: Internal editor callback
    @ObservedObject private var settings = FeatureSettings.shared

    func makeNSView(context: Context) -> UnifiedTerminalContainerView {
        // Rust is the default backend when the library is available.
        // SwiftTerm serves as a fallback for builds without the Rust dylib.
        // The setting provides an opt-out for users who prefer SwiftTerm.
        let useRust = RustTerminalView.isAvailable && settings.isRustTerminalEnabled

        if useRust {
            Log.info("Using Rust terminal backend (default)")
            return makeRustTerminalView()
        } else {
            if !RustTerminalView.isAvailable {
                Log.info("Using SwiftTerm fallback (Rust library not available)")
            } else {
                Log.info("Using SwiftTerm backend (Rust disabled by user setting)")
            }
            return makeSwiftTermView()
        }
    }

    // MARK: - SwiftTerm Backend (fallback)

    private func makeSwiftTermView() -> UnifiedTerminalContainerView {
        // Reuse existing terminal view if available (preserves shell session across SwiftUI view recreations)
        if let existingView = model.existingTerminalView {
            Log.trace("Reusing existing SwiftTerm view for session")
            existingView.notifyUpdateChanges = !isSuspended
            existingView.isHidden = isSuspended
            existingView.setEventMonitoringEnabled(isActive && !isSuspended)
            existingView.allowMouseReporting = settings.isMouseReportingEnabled
            existingView.onFilePathClicked = onFilePathClicked
            existingView.onScrollbackCleared = { [weak model] in
                model?.resetDangerousHighlights()
            }
            existingView.onScrollChanged = { [weak model] in
                model?.scheduleHighlightAfterScroll()
            }
            existingView.tabIdentifier = model.tabIdentifier
            existingView.isAtPrompt = { [weak model] in model?.isAtPrompt ?? false }
            existingView.installHistoryKeyMonitor()
            return UnifiedTerminalContainerView(swiftTermView: existingView)
        }

        // Create new terminal view and start shell process
        let view = Chau7TerminalView(frame: .zero)
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
        view.allowMouseReporting = settings.isMouseReportingEnabled
        view.onInput = { [weak model] text in
            model?.handleInput(text)
        }
        view.onOutput = { [weak model] data in
            model?.handleOutput(data)
        }
        view.onBufferChanged = { [weak model] in
            model?.scheduleSearchRefresh()
            model?.highlightView?.scheduleDisplay()
            model?.recordOutputLatencyIfNeeded()
        }
        view.onScrollChanged = { [weak model] in
            model?.scheduleHighlightAfterScroll()
        }
        view.onFilePathClicked = onFilePathClicked
        view.onScrollbackCleared = { [weak model] in
            model?.resetDangerousHighlights()
        }
        view.tabIdentifier = model.tabIdentifier
        view.isAtPrompt = { [weak model] in model?.isAtPrompt ?? false }
        view.installHistoryKeyMonitor()

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

        let container = UnifiedTerminalContainerView(swiftTermView: view)
        container.onFirstSwiftTermLayout = { [weak model, weak view] terminalView in
            guard let model, let view else { return }
            let tip = PowerUserTips.randomFormattedTip()
            if let headerBox = terminalHeaderBox(cols: terminalView.getTerminal().cols, message: tip) {
                terminalView.feed(text: headerBox)
            }

            let shell = model.defaultShell()
            let execName = "-" + URL(fileURLWithPath: shell).lastPathComponent
            let env = model.buildEnvironment()
            let args = model.shellArguments()
            terminalView.startProcess(executable: shell, args: args, environment: env, execName: execName)

            model.attachTerminal(view)
            model.applyFontSize()
            model.scheduleShellIntegration(for: view)
        }
        return container
    }

    // MARK: - Rust Backend (experimental)

    private func makeRustTerminalView() -> UnifiedTerminalContainerView {
        // Reuse existing Rust terminal view if available
        if let existingView = model.existingRustTerminalView {
            Log.trace("Reusing existing Rust terminal view for session")
            existingView.notifyUpdateChanges = !isSuspended
            existingView.isHidden = isSuspended
            existingView.setEventMonitoringEnabled(isActive && !isSuspended)
            existingView.allowMouseReporting = settings.isMouseReportingEnabled
            existingView.onFilePathClicked = onFilePathClicked
            existingView.onScrollbackCleared = { [weak model] in
                model?.resetDangerousHighlights()
            }
            existingView.onScrollChanged = { [weak model] in
                model?.scheduleHighlightAfterScroll()
            }
            existingView.tabIdentifier = model.tabIdentifier
            existingView.isAtPrompt = { [weak model] in model?.isAtPrompt ?? false }
            existingView.installHistoryKeyMonitor()
            return UnifiedTerminalContainerView(rustView: existingView)
        }

        // Create new Rust terminal view
        Log.info("Creating new Rust terminal view")
        let view = RustTerminalView(frame: .zero)

        // Configure shell and environment before terminal starts (must be before first layout)
        let shell = model.defaultShell()
        let environmentArray = model.buildEnvironment()
        // Convert [String] ("KEY=VALUE") to [String: String] for Rust FFI
        var environmentDict: [String: String] = [:]
        for entry in environmentArray {
            if let idx = entry.firstIndex(of: "=") {
                let key = String(entry[..<idx])
                let value = String(entry[entry.index(after: idx)...])
                environmentDict[key] = value
            }
        }
        view.configureShell(shell)
        view.configureEnvironment(environmentDict)
        Log.info("Configured Rust terminal with shell: \(shell), env vars: \(environmentDict.count)")

        view.font = terminalFont()
        view.applyColorScheme(settings.currentColorScheme)
        view.applyCursorStyle(style: settings.cursorStyle, blink: settings.cursorBlink)
        view.applyBellSettings(enabled: settings.bellEnabled, sound: settings.bellSound)
        view.applyScrollbackLines(settings.scrollbackLines)
        view.notifyUpdateChanges = !isSuspended
        view.isHidden = isSuspended
        view.setEventMonitoringEnabled(isActive && !isSuspended)
        view.allowMouseReporting = settings.isMouseReportingEnabled
        view.onInput = { [weak model] text in
            model?.handleInput(text)
        }
        view.onOutput = { [weak model] data in
            model?.handleOutput(data)
        }
        view.onBufferChanged = { [weak model] in
            model?.scheduleSearchRefresh()
            model?.highlightView?.scheduleDisplay()
            model?.recordOutputLatencyIfNeeded()
        }
        view.onScrollChanged = { [weak model] in
            model?.scheduleHighlightAfterScroll()
        }
        view.onFilePathClicked = onFilePathClicked
        view.onScrollbackCleared = { [weak model] in
            model?.resetDangerousHighlights()
        }
        view.tabIdentifier = model.tabIdentifier
        view.isAtPrompt = { [weak model] in model?.isAtPrompt ?? false }
        view.installHistoryKeyMonitor()

        view.wantsLayer = true
        view.layer?.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]

        // Set up cursor line view for Rust terminal
        let cursorLineView = TerminalCursorLineView(frame: .zero)
        cursorLineView.autoresizingMask = [.width, .height]
        cursorLineView.wantsLayer = true
        cursorLineView.layer?.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "opacity": NSNull()]
        view.addSubview(cursorLineView)
        view.attachCursorLineView(cursorLineView)

        // Set up highlight view for Rust terminal
        let highlightView = TerminalHighlightView(frame: .zero)
        highlightView.rustTerminalView = view
        highlightView.session = model
        highlightView.autoresizingMask = [.width, .height]
        highlightView.wantsLayer = true
        highlightView.layer?.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        highlightView.layer?.backgroundColor = NSColor.clear.cgColor
        view.addSubview(highlightView)
        highlightView.frame = view.bounds
        model.attachHighlightView(highlightView)

        let container = UnifiedTerminalContainerView(rustView: view)
        container.onFirstRustLayout = { [weak model, weak view] rustView in
            guard let model, let view else { return }

            // Display power user tip directly in the terminal output (parity with SwiftTerm path)
            let tip = PowerUserTips.randomFormattedTip()
            let headerBox = terminalHeaderBox(cols: rustView.renderCols, message: tip)

            // Start the Rust terminal now that we have proper dimensions
            rustView.startTerminal(initialOutput: headerBox)

            model.attachRustTerminal(view)
            model.applyFontSize()
        }
        return container
    }

    func updateNSView(_ container: UnifiedTerminalContainerView, context: Context) {
        if container.usesRustBackend {
            updateRustTerminalView(container)
        } else {
            updateSwiftTermView(container)
        }
    }

    private func updateSwiftTermView(_ container: UnifiedTerminalContainerView) {
        guard let nsView = container.swiftTerminalView else { return }
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
        nsView.setCursorLineHighlightEnabled(false)
        nsView.configureCursorLineHighlight(contextLines: false, inputHistory: false)

        let desiredFont = terminalFont()
        if nsView.font.fontName != desiredFont.fontName || nsView.font.pointSize != desiredFont.pointSize {
            nsView.font = desiredFont
        }
        nsView.applyColorScheme(settings.currentColorScheme)
        nsView.applyCursorStyle(style: settings.cursorStyle, blink: settings.cursorBlink)
        nsView.applyBellSettings(enabled: settings.bellEnabled, sound: settings.bellSound)
        nsView.applyScrollbackLines(settings.scrollbackLines)
    }

    private func updateRustTerminalView(_ container: UnifiedTerminalContainerView) {
        guard let nsView = container.rustTerminalView else { return }
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
        nsView.setCursorLineHighlightEnabled(false)
        nsView.configureCursorLineHighlight(contextLines: false, inputHistory: false)

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
    let interiorWidth = boxWidth - 18
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
