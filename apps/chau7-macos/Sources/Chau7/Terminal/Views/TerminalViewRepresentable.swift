import SwiftUI
import AppKit
import QuartzCore
import Chau7Core

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

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    /// Weak reference to the shared Metal coordinator. Set by `switchToView()`
    /// so the container can resize it on layout without owning it.
    weak var metalCoordinator: RustMetalDisplayCoordinator?

    override func layout() {
        super.layout()
        terminalView.frame = bounds

        // Resize the shared Metal view if it's placed in this container.
        // Guard against degenerate dimensions during split pane transitions —
        // the container can have zero bounds momentarily, causing renderRows/
        // renderCols to return 1. A 1x1 resize corrupts the triple buffer.
        if let coordinator = metalCoordinator {
            let inset = RustTerminalView.terminalInset
            let rows = terminalView.renderRows
            let cols = terminalView.renderCols
            if rows > 1, cols > 1 {
                coordinator.metalView.frame = bounds.insetBy(dx: inset, dy: inset)
                coordinator.resize(rows: rows, cols: cols)
            }
        }

        if !didRunFirstLayout, bounds.width > 0, bounds.height > 0 {
            didRunFirstLayout = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                terminalView.layoutSubtreeIfNeeded()
                onFirstLayout?(terminalView)
            }
        }
    }
}

/// Terminal container view (Rust backend only).
final class UnifiedTerminalContainerView: NSView {
    private var rustContainer: RustTerminalContainerView?

    init(rustView: RustTerminalView) {
        self.rustContainer = RustTerminalContainerView(terminalView: rustView)
        super.init(frame: .zero)
        addSubview(rustContainer!)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func layout() {
        super.layout()
        rustContainer?.frame = bounds
    }

    var rustTerminalView: RustTerminalView? {
        rustContainer?.terminalView
    }

    var onFirstRustLayout: ((RustTerminalView) -> Void)? {
        get { rustContainer?.onFirstLayout }
        set { rustContainer?.onFirstLayout = newValue }
    }

    /// The inner RustTerminalContainerView, exposed for the shared Metal
    /// coordinator's switchToView() to reparent the Metal NSView.
    var innerRustContainer: RustTerminalContainerView? {
        rustContainer
    }

    /// Whether the contained terminal view has Metal rendering active.
    var isMetalActive: Bool {
        rustTerminalView?.isMetalRenderingActive ?? false
    }
}

struct TerminalViewRepresentable: NSViewRepresentable {
    final class Coordinator {
        var lastRenderPhase: TabRenderPhase?

        func seedRenderPhase(_ renderPhase: TabRenderPhase) {
            lastRenderPhase = renderPhase
        }

        func consumeRenderPhaseTransition(to renderPhase: TabRenderPhase) -> (previous: TabRenderPhase?, changed: Bool) {
            let previous = lastRenderPhase
            let changed = previous != renderPhase
            lastRenderPhase = renderPhase
            return (previous, changed)
        }
    }

    var model: TerminalSessionModel
    var renderPhase: TabRenderPhase
    var isInteractive: Bool
    var onFilePathClicked: ((String, Int?, Int?) -> Void)?
    var settings = FeatureSettings.shared

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @discardableResult
    private static func startTerminalIfReady(
        model: TerminalSessionModel,
        container: UnifiedTerminalContainerView,
        rustView: RustTerminalView,
        useMetalRenderer: Bool,
        isSelectedTab: Bool = false,
        reason: String
    ) -> Bool {
        container.layoutSubtreeIfNeeded()
        let shouldStart = TerminalStartupPolicy.shouldStartTerminal(
            isStarted: rustView.isTerminalStarted,
            containerWidth: container.bounds.width,
            containerHeight: container.bounds.height,
            rustViewWidth: rustView.bounds.width,
            rustViewHeight: rustView.bounds.height
        )
        guard shouldStart else {
            if !rustView.isTerminalStarted {
                Log.trace(
                    "TerminalViewRepresentable: startTerminal deferred [\(reason)] container=\(container.bounds.debugDescription) rust=\(rustView.bounds.debugDescription)"
                )
            }
            return false
        }

        // With event-driven rendering (zero idle CPU), all terminals can
        // launch immediately — no need to serialize via the startup queue.
        launchTerminal(model: model, container: container, rustView: rustView, useMetalRenderer: useMetalRenderer, reason: reason)
        return true
    }

    private static func launchTerminal(
        model: TerminalSessionModel,
        container: UnifiedTerminalContainerView,
        rustView: RustTerminalView,
        useMetalRenderer: Bool,
        reason: String
    ) {
        guard !rustView.isTerminalStarted else { return }

        let tip = PowerUserTips.randomFormattedTip()
        let headerBox = terminalHeaderBox(cols: rustView.renderCols, message: tip)
        rustView.startTerminal(initialOutput: headerBox)
        rustView.appliedColorSchemeSignature = nil
        rustView.applyColorScheme(FeatureSettings.shared.currentColorScheme)
        model.attachRustTerminal(rustView)

        // Notify the window-level tabs model that a terminal started, so the
        // shared Metal coordinator can be created/attached if this is the selected tab.
        NotificationCenter.default.post(name: .terminalDidStart, object: nil)

        Log.info("TerminalViewRepresentable: started terminal [\(reason)]")
    }

    private func liveEligibilitySummary() -> String {
        var reasons: [String] = []
        if isInteractive {
            reasons.append("selected")
        } else if renderPhase.keepsVisibleSurface {
            reasons.append("visible-noninteractive")
        } else if renderPhase == .warm {
            reasons.append("handoff")
        }
        reasons.append(contentsOf: model.backgroundLiveRenderReasons())
        return reasons.isEmpty ? "none" : Array(NSOrderedSet(array: reasons)).compactMap { $0 as? String }.joined(separator: ",")
    }

    func makeNSView(context: Context) -> UnifiedTerminalContainerView {
        Log.trace("TerminalViewRepresentable: makeNSView — Rust backend")
        let container = makeRustTerminalView()
        context.coordinator.seedRenderPhase(renderPhase)
        return container
    }

    private func makeRustTerminalView() -> UnifiedTerminalContainerView {
        if let existingContainer = model.existingTerminalContainerView,
           let existingView = existingContainer.rustTerminalView {
            Log.trace("Reusing existing Rust terminal container for session")
            existingView.onInput = { [weak model] text in
                model?.handleInput(text)
            }
            existingView.shouldAcceptUserText = { [weak model] text in
                model?.shouldAcceptDirectUserInput(text) ?? true
            }
            existingView.onOutput = { [weak model] data in
                model?.handleOutput(data)
            }
            existingView.onShellStartupSlow = { [weak model] in
                model?.shellStartupSlow = true
            }
            existingView.onBufferChanged = { [weak model, weak existingView] in
                model?.scheduleSearchRefresh()
                model?.highlightView?.scheduleDisplay()
                model?.recordOutputLatencyIfNeeded()
                model?.noteRestoreBootstrapBufferChanged()
                if existingView?.isMetalRenderingActive == false {
                    model?.notifyVisibleFrameReadyIfNeeded()
                }
            }
            existingView.onFramePresented = { [weak model] in
                model?.notifyVisibleFrameReadyIfNeeded()
            }
            existingView.onFilePathClicked = onFilePathClicked
            existingView.onScrollbackCleared = { [weak model] in
                model?.resetDangerousHighlights()
            }
            existingView.onScrollChanged = { [weak model] in
                model?.scheduleHighlightAfterScroll()
            }
            existingView.tabIdentifier = model.tabIdentifier
            existingView.isAtPrompt = { [weak model] in model?.isAtPrompt ?? false }
            existingView.liveEligibilityReasonForProfiling = liveEligibilitySummary()
            existingView.installHistoryKeyMonitor()
            existingView.applyRenderPhase(renderPhase, isInteractive: isInteractive, reason: "reuse-container")
            existingView.allowMouseReporting = settings.isMouseReportingEnabled
            // Metal rendering is managed by the shared window-level coordinator.
            // Ensure the view flag is correct — the coordinator will attach when
            // this tab becomes selected via switchToView().
            if !settings.useMetalRenderer {
                existingView.isMetalRenderingActive = false
            }
            return existingContainer
        }

        // Reuse existing Rust terminal view if available
        if let existingView = model.existingRustTerminalView {
            Log.trace("Reusing existing Rust terminal view for session")
            existingView.onInput = { [weak model] text in
                model?.handleInput(text)
            }
            existingView.shouldAcceptUserText = { [weak model] text in
                model?.shouldAcceptDirectUserInput(text) ?? true
            }
            existingView.onOutput = { [weak model] data in
                model?.handleOutput(data)
            }
            existingView.onShellStartupSlow = { [weak model] in
                model?.shellStartupSlow = true
            }
            existingView.onBufferChanged = { [weak model, weak existingView] in
                model?.scheduleSearchRefresh()
                model?.highlightView?.scheduleDisplay()
                model?.recordOutputLatencyIfNeeded()
                model?.noteRestoreBootstrapBufferChanged()
                if existingView?.isMetalRenderingActive == false {
                    model?.notifyVisibleFrameReadyIfNeeded()
                }
            }
            existingView.onFramePresented = { [weak model] in
                model?.notifyVisibleFrameReadyIfNeeded()
            }
            existingView.onFilePathClicked = onFilePathClicked
            existingView.onScrollbackCleared = { [weak model] in
                model?.resetDangerousHighlights()
            }
            existingView.onScrollChanged = { [weak model] in
                model?.scheduleHighlightAfterScroll()
            }
            existingView.tabIdentifier = model.tabIdentifier
            existingView.isAtPrompt = { [weak model] in model?.isAtPrompt ?? false }
            existingView.liveEligibilityReasonForProfiling = liveEligibilitySummary()
            existingView.installHistoryKeyMonitor()
            let container = UnifiedTerminalContainerView(rustView: existingView)
            model.attachTerminalContainer(container)
            existingView.applyRenderPhase(renderPhase, isInteractive: isInteractive, reason: "reuse")
            existingView.allowMouseReporting = settings.isMouseReportingEnabled
            // Metal rendering is managed by the shared window-level coordinator.
            // Clear the flag so the CPU renderer is active until the coordinator
            // attaches via switchToView() when this tab becomes selected.
            existingView.isMetalRenderingActive = false
            return container
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
        view.applyRenderPhase(renderPhase, isInteractive: isInteractive, reason: "create")
        view.allowMouseReporting = settings.isMouseReportingEnabled
        view.onInput = { [weak model] text in
            model?.handleInput(text)
        }
        view.shouldAcceptUserText = { [weak model] text in
            model?.shouldAcceptDirectUserInput(text) ?? true
        }
        view.onOutput = { [weak model] data in
            model?.handleOutput(data)
        }
        view.onShellStartupSlow = { [weak model] in
            model?.shellStartupSlow = true
        }
        view.onBufferChanged = { [weak model, weak view] in
            model?.scheduleSearchRefresh()
            model?.highlightView?.scheduleDisplay()
            model?.recordOutputLatencyIfNeeded()
            model?.noteRestoreBootstrapBufferChanged()
            if view?.isMetalRenderingActive == false {
                model?.notifyVisibleFrameReadyIfNeeded()
            }
        }
        view.onFramePresented = { [weak model] in
            model?.notifyVisibleFrameReadyIfNeeded()
        }
        view.onScrollChanged = { [weak model] in
            model?.scheduleHighlightAfterScroll()
        }
        view.onFilePathClicked = onFilePathClicked
        view.onScrollbackCleared = { [weak model] in
            model?.resetDangerousHighlights()
        }
        view.dangerousRowTintsProvider = { [weak model] top, bottom in
            model?.dangerousRowTints(top: top, bottom: bottom) ?? [:]
        }
        view.tabIdentifier = model.tabIdentifier
        view.isAtPrompt = { [weak model] in model?.isAtPrompt ?? false }
        view.liveEligibilityReasonForProfiling = liveEligibilitySummary()
        view.installHistoryKeyMonitor()

        view.wantsLayer = true
        view.layer?.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]

        // Set up cursor line view
        let cursorLineView = TerminalCursorLineView(frame: .zero)
        cursorLineView.autoresizingMask = [.width, .height]
        cursorLineView.wantsLayer = true
        cursorLineView.layer?.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "opacity": NSNull()]
        view.addSubview(cursorLineView)
        view.attachCursorLineView(cursorLineView)

        // Set up highlight view
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
        model.attachTerminalContainer(container)
        let useMetalRenderer = settings.useMetalRenderer
        let isSelectedTab = isInteractive
        container.onFirstRustLayout = { [weak model, weak container] rustView in
            guard let model, let container else { return }
            _ = Self.startTerminalIfReady(
                model: model,
                container: container,
                rustView: rustView,
                useMetalRenderer: useMetalRenderer,
                isSelectedTab: isSelectedTab,
                reason: "first_layout"
            )
        }
        return container
    }

    func updateNSView(_ container: UnifiedTerminalContainerView, context: Context) {
        guard let nsView = container.rustTerminalView else { return }
        nsView.liveEligibilityReasonForProfiling = liveEligibilitySummary()
        let transition = context.coordinator.consumeRenderPhaseTransition(to: renderPhase)
        let keepsVisibleSurface = renderPhase.keepsVisibleSurface
        let allowsLivePresentation = renderPhase.allowsLivePresentation
        nsView.applyRenderPhase(renderPhase, isInteractive: isInteractive, reason: "updateNSView")
        _ = Self.startTerminalIfReady(
            model: model,
            container: container,
            rustView: nsView,
            useMetalRenderer: settings.useMetalRenderer,
            reason: "update_ns_view"
        )
        let shouldForceAuthoritativeReveal = TabRenderLifecyclePolicy.requiresAuthoritativeReveal(
            previousPhase: transition.previous,
            nextPhase: renderPhase
        )
        if shouldForceAuthoritativeReveal {
            nsView.requestAuthoritativeReveal(reason: "renderPhaseActivated")
        }
        if keepsVisibleSurface {
            nsView.needsDisplay = true
        }

        // Reconcile shared Metal coordinator: if this is the selected tab
        // with a terminal but Metal isn't active, directly attach the
        // coordinator. No notification — avoids the infinite loop.
        if allowsLivePresentation,
           settings.useMetalRenderer,
           nsView.isTerminalStarted,
           !nsView.isMetalRenderingActive,
           let rustContainer = container.innerRustContainer,
           rustContainer.metalCoordinator == nil,
           let coordinator = model.windowMetalCoordinator {
            coordinator.switchToView(nsView, container: rustContainer)
            coordinator.metalView.isHidden = !keepsVisibleSurface
        }

        nsView.updatePollingMode(reason: "updateNSView")
        if allowsLivePresentation,
           nsView.window != nil,
           !nsView.livePollingActiveForProfiling || shouldForceAuthoritativeReveal {
            nsView.needsGridSync = true
            nsView.pollAndSync()
        }
        nsView.setCursorLineHighlightEnabled(false)
        nsView.configureCursorLineHighlight(contextLines: false, inputHistory: false)

        let desiredFont = terminalFont()
        let fontChanged = nsView.font.fontName != desiredFont.fontName || nsView.font.pointSize != desiredFont.pointSize
        if fontChanged {
            nsView.font = desiredFont
        }

        let scheme = settings.currentColorScheme
        nsView.applyColorScheme(scheme)

        nsView.applyCursorStyle(style: settings.cursorStyle, blink: settings.cursorBlink)
        nsView.applyBellSettings(enabled: settings.bellEnabled, sound: settings.bellSound)
        nsView.applyScrollbackLines(settings.scrollbackLines)
    }

    static func dismantleNSView(_ container: UnifiedTerminalContainerView, coordinator _: Coordinator) {
        guard let nsView = container.rustTerminalView else { return }

        // When SwiftUI removes a terminal from the live hierarchy, the session
        // still retains the view for later reuse. Force it onto the hidden
        // background-drain path now so old selected tabs do not keep spinning
        // event drain work after a switch.
        nsView.applyRenderPhase(.hidden, isInteractive: false, reason: "dismantleNSView")
        nsView.isHidden = true
        nsView.updatePollingMode(reason: "dismantleNSView")
    }

    private func terminalFont() -> NSFont {
        return TerminalFont.resolveFont(family: settings.fontFamily, size: model.fontSize)
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
        ("\u{1F4A1}", "TIP"),
        ("\u{2318}", "CMD+"),
        ("\u{21E7}", "SHIFT+"),
        ("\u{2325}", "OPT+"),
        ("\u{2303}", "CTRL+"),
        ("\u{2192}", "->"),
        ("\u{2190}", "<-"),
        ("\u{2191}", "^"),
        ("\u{2193}", "v"),
        ("\u{2022}", "*")
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
