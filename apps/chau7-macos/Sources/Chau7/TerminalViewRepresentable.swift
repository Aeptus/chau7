import SwiftUI
import AppKit
import SwiftTerm
import QuartzCore

/// Container view for the terminal (no inset needed - content is below toolbar)
final class TerminalContainerView: NSView {
    let terminalView: Chau7TerminalView
    var onFirstLayout: ((Chau7TerminalView) -> Void)?
    private var didRunFirstLayout = false

    /// Metal display coordinator (nil when Metal rendering is disabled)
    private(set) var metalCoordinator: MetalDisplayCoordinator?

    /// Original onBufferChanged callback saved before Metal chaining, restored on disable.
    private var preMetalBufferChangedCallback: (() -> Void)?

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
        metalCoordinator?.metalView.frame = bounds

        // Propagate terminal resize to the Metal coordinator
        if let coordinator = metalCoordinator {
            let terminal = terminalView.getTerminal()
            coordinator.resize(rows: terminal.rows, cols: terminal.cols)
        }

        if !didRunFirstLayout && bounds.width > 0 && bounds.height > 0 {
            didRunFirstLayout = true
            onFirstLayout?(terminalView)
        }
    }

    /// Enables Metal GPU rendering overlay.
    /// SwiftTerm remains fully visible and interactive (handles mouse events, selection).
    /// Metal view sits on top as an opaque display layer with event passthrough.
    /// HighlightView (if present) is moved above Metal so highlights remain visible.
    func enableMetalRendering() {
        guard metalCoordinator == nil else { return }
        guard let coordinator = MetalDisplayCoordinator(terminalView: terminalView) else {
            Log.warn("TerminalContainerView: Metal rendering unavailable, keeping SwiftTerm display")
            return
        }

        metalCoordinator = coordinator

        // Add Metal view on top of SwiftTerm. Metal is opaque and covers SwiftTerm's
        // cell rendering. Mouse events pass through Metal to SwiftTerm (hitTest returns nil).
        let metalView = coordinator.metalView
        metalView.frame = bounds
        metalView.autoresizingMask = [.width, .height]
        addSubview(metalView, positioned: .above, relativeTo: terminalView)

        // Move HighlightView above Metal view so search/danger highlights remain visible.
        for subview in terminalView.subviews {
            if subview is TerminalHighlightView {
                subview.removeFromSuperview()
                subview.frame = bounds
                addSubview(subview, positioned: .above, relativeTo: metalView)
                break
            }
        }

        // Save the original callback before wrapping it with Metal sync.
        preMetalBufferChangedCallback = terminalView.onBufferChanged
        chainMetalSync(coordinator: coordinator)

        Log.info("TerminalContainerView: Metal rendering enabled")
    }

    /// Re-chains the Metal sync wrapper onto the current onBufferChanged callback.
    /// Called from enableMetalRendering() and after updateNSView resets the callback.
    func chainMetalSync(coordinator: MetalDisplayCoordinator) {
        let baseCallback = terminalView.onBufferChanged
        terminalView.onBufferChanged = { [weak coordinator] in
            baseCallback?()
            coordinator?.setNeedsSync()
        }
    }

    /// Disables Metal rendering, showing SwiftTerm's native display again.
    func disableMetalRendering() {
        guard let coordinator = metalCoordinator else { return }
        coordinator.stop()

        // Restore the original onBufferChanged callback (before Metal chaining)
        if let original = preMetalBufferChangedCallback {
            terminalView.onBufferChanged = original
        }
        preMetalBufferChangedCallback = nil

        // Move HighlightView back into the terminal view
        for subview in subviews {
            if subview is TerminalHighlightView {
                subview.removeFromSuperview()
                terminalView.addSubview(subview)
                subview.frame = terminalView.bounds
                break
            }
        }

        coordinator.metalView.removeFromSuperview()
        metalCoordinator = nil
        Log.info("TerminalContainerView: Metal rendering disabled")
    }
}

/// Container view for the Rust terminal backend
final class RustTerminalContainerView: NSView {
    let terminalView: RustTerminalView
    var onFirstLayout: ((RustTerminalView) -> Void)?
    private var didRunFirstLayout = false

    /// Rust Metal display coordinator (nil when Metal rendering is disabled)
    private(set) var rustMetalCoordinator: RustMetalDisplayCoordinator?

    /// Original onBufferChanged callback saved before Metal chaining, restored on disable.
    private var preMetalBufferChangedCallback: (() -> Void)?

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
        rustMetalCoordinator?.metalView.frame = bounds

        // Propagate terminal resize to the Metal coordinator
        if let coordinator = rustMetalCoordinator {
            coordinator.resize(rows: terminalView.renderRows, cols: terminalView.renderCols)
        }

        if !didRunFirstLayout && bounds.width > 0 && bounds.height > 0 {
            didRunFirstLayout = true
            // Defer the first-layout callback to the next runloop pass so that
            // this layout cycle finishes first — avoids the AppKit warning about
            // calling layoutSubtreeIfNeeded inside an active layout pass.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.terminalView.layoutSubtreeIfNeeded()
                self.onFirstLayout?(self.terminalView)
            }
        }
    }

    /// Enables Metal GPU rendering overlay for the Rust terminal.
    /// The RustGridView (CPU renderer) stays in place as a fallback.
    /// Metal view sits on top as an opaque display layer with event passthrough.
    /// HighlightView (if present) is moved above Metal so highlights remain visible.
    func enableMetalRendering() {
        guard rustMetalCoordinator == nil else { return }

        // Create a grid provider closure that reads from the Rust terminal FFI
        guard let gridProvider = terminalView.makeGridProvider() else {
            Log.warn("RustTerminalContainerView: Cannot create grid provider, keeping CPU rendering")
            return
        }

        guard let coordinator = RustMetalDisplayCoordinator(
            terminalView: terminalView,
            gridProvider: gridProvider
        ) else {
            Log.warn("RustTerminalContainerView: Metal rendering unavailable, keeping CPU rendering")
            return
        }

        rustMetalCoordinator = coordinator

        // Add Metal view on top of RustGridView. Metal is opaque and covers the CPU renderer.
        // Mouse events pass through Metal to the terminal view (hitTest returns nil).
        let metalView = coordinator.metalView
        metalView.frame = bounds
        metalView.autoresizingMask = [.width, .height]
        addSubview(metalView, positioned: .above, relativeTo: terminalView)

        // Move HighlightView above Metal view so search/danger highlights remain visible.
        for subview in terminalView.subviews {
            if subview is TerminalHighlightView {
                subview.removeFromSuperview()
                subview.frame = bounds
                addSubview(subview, positioned: .above, relativeTo: metalView)
                break
            }
        }

        // Save the original callback before wrapping it with Metal sync.
        preMetalBufferChangedCallback = terminalView.onBufferChanged
        chainMetalSync(coordinator: coordinator)

        // Suppress CPU rendering — Metal handles display now.
        // This skips syncGridToRenderer(), tickCursorBlink(), and RustGridView.draw().
        terminalView.isMetalRenderingActive = true

        // Force an immediate Metal render so the first frame isn't blank.
        // The Metal view sits on top of the CPU renderer, so if we don't
        // trigger a draw now, the user sees nothing until the next pollAndSync().
        coordinator.setNeedsSync()

        Log.info("RustTerminalContainerView: Metal rendering enabled")
    }

    /// Re-chains the Metal sync wrapper onto the current onBufferChanged callback.
    func chainMetalSync(coordinator: RustMetalDisplayCoordinator) {
        let baseCallback = terminalView.onBufferChanged
        terminalView.onBufferChanged = { [weak coordinator] in
            baseCallback?()
            coordinator?.setNeedsSync()
        }
    }

    /// Disables Metal rendering, showing the CPU RustGridView again.
    func disableMetalRendering() {
        guard let coordinator = rustMetalCoordinator else { return }
        coordinator.stop()

        // Re-enable CPU rendering path
        terminalView.isMetalRenderingActive = false

        // Restore the original onBufferChanged callback (before Metal chaining)
        if let original = preMetalBufferChangedCallback {
            terminalView.onBufferChanged = original
        }
        preMetalBufferChangedCallback = nil

        // Move HighlightView back into the terminal view
        for subview in subviews {
            if subview is TerminalHighlightView {
                subview.removeFromSuperview()
                terminalView.addSubview(subview)
                subview.frame = terminalView.bounds
                break
            }
        }

        coordinator.metalView.removeFromSuperview()
        rustMetalCoordinator = nil
        Log.info("RustTerminalContainerView: Metal rendering disabled")
    }
}

/// Unified container that holds either SwiftTerm or Rust terminal
final class UnifiedTerminalContainerView: NSView {
    private var swiftTermContainer: TerminalContainerView?
    private var rustContainer: RustTerminalContainerView?

    /// Whether this container uses the Rust backend
    let usesRustBackend: Bool

    /// Tracks the last applied color scheme for Metal coordinator notifications.
    var lastMetalColorSchemeSignature: String?

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

    /// Enables Metal GPU rendering for the active backend.
    func enableMetalRendering() {
        if usesRustBackend {
            rustContainer?.enableMetalRendering()
        } else {
            swiftTermContainer?.enableMetalRendering()
        }
    }

    /// Disables Metal GPU rendering, restoring the native CPU display.
    func disableMetalRendering() {
        if usesRustBackend {
            rustContainer?.disableMetalRendering()
        } else {
            swiftTermContainer?.disableMetalRendering()
        }
    }

    /// The active SwiftTerm Metal coordinator, if Metal rendering is enabled.
    var metalCoordinator: MetalDisplayCoordinator? {
        swiftTermContainer?.metalCoordinator
    }

    /// The active Rust Metal coordinator, if Metal rendering is enabled.
    var rustMetalCoordinator: RustMetalDisplayCoordinator? {
        rustContainer?.rustMetalCoordinator
    }

    /// Whether Metal rendering is active on either backend.
    var isMetalActive: Bool {
        metalCoordinator != nil || rustMetalCoordinator != nil
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
            Log.trace("TerminalViewRepresentable: makeNSView — Rust backend")
            return makeRustTerminalView()
        } else {
            if !RustTerminalView.isAvailable {
                Log.trace("TerminalViewRepresentable: makeNSView — SwiftTerm fallback (Rust library not available)")
            } else {
                Log.trace("TerminalViewRepresentable: makeNSView — SwiftTerm (Rust disabled by user setting)")
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
            let container = UnifiedTerminalContainerView(swiftTermView: existingView)
            // Re-enable Metal rendering — the previous container (and its Metal
            // coordinator) was torn down when the tab went out of nearby range.
            // SwiftTerm's CPU rendering still works (unlike Rust, it has no
            // isMetalRenderingActive gate), but we want GPU acceleration back.
            if settings.useMetalRenderer {
                container.enableMetalRendering()
                Log.trace("Re-enabled Metal rendering for reused SwiftTerm view")
            }
            return container
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
        let useMetalRenderer = settings.useMetalRenderer
        container.onFirstSwiftTermLayout = { [weak model, weak view, weak container] terminalView in
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

            // Enable Metal GPU rendering if the setting is on
            if useMetalRenderer {
                container?.enableMetalRendering()
            }
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
            let container = UnifiedTerminalContainerView(rustView: existingView)
            // Re-enable Metal rendering — the previous container (and its Metal
            // coordinator) was torn down when the tab went out of nearby range.
            // Without this, isMetalRenderingActive stays true on the view (skipping
            // CPU rendering) while no Metal coordinator exists (no GPU rendering
            // either), leaving the tab blank/grey.
            if settings.useMetalRenderer {
                // Reset the flag so enableMetalRendering() can re-attach
                existingView.isMetalRenderingActive = false
                container.enableMetalRendering()
                Log.trace("Re-enabled Metal rendering for reused Rust terminal view")
            }
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
        let useMetalRenderer = settings.useMetalRenderer
        container.onFirstRustLayout = { [weak model, weak view, weak container] rustView in
            guard let model, let view else { return }

            // Display power user tip directly in the terminal output (parity with SwiftTerm path)
            let tip = PowerUserTips.randomFormattedTip()
            let headerBox = terminalHeaderBox(cols: rustView.renderCols, message: tip)

            // Start the Rust terminal now that we have proper dimensions
            rustView.startTerminal(initialOutput: headerBox)

            model.attachRustTerminal(view)
            model.applyFontSize()

            // Enable Metal GPU rendering if the setting is on
            if useMetalRenderer {
                container?.enableMetalRendering()
            }
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

        // SwiftTerm stays visible even when Metal is active (Metal covers it visually
        // but SwiftTerm handles mouse events, selection, and draws underneath).
        let metalActive = container.metalCoordinator != nil
        if nsView.isHidden != isSuspended {
            nsView.isHidden = isSuspended
            if !isSuspended {
                nsView.needsDisplay = true
            }
        }

        // Suspend/resume Metal view alongside the terminal
        if metalActive {
            container.metalCoordinator?.metalView.isHidden = isSuspended
        }
        if nsView.notifyUpdateChanges == isSuspended {
            nsView.notifyUpdateChanges = !isSuspended
        }
        nsView.setCursorLineHighlightEnabled(false)
        nsView.configureCursorLineHighlight(contextLines: false, inputHistory: false)

        let desiredFont = terminalFont()
        let fontChanged = nsView.font.fontName != desiredFont.fontName || nsView.font.pointSize != desiredFont.pointSize
        if fontChanged {
            nsView.font = desiredFont
            container.metalCoordinator?.fontChanged()
        }

        let scheme = settings.currentColorScheme
        nsView.applyColorScheme(scheme)

        // Notify Metal coordinator only when the color scheme actually changes
        if metalActive {
            let sig = scheme.signature
            if container.lastMetalColorSchemeSignature != sig {
                container.lastMetalColorSchemeSignature = sig
                container.metalCoordinator?.colorSchemeChanged()
            }
        }

        nsView.applyCursorStyle(style: settings.cursorStyle, blink: settings.cursorBlink)
        nsView.applyBellSettings(enabled: settings.bellEnabled, sound: settings.bellSound)
        nsView.applyScrollbackLines(settings.scrollbackLines)
    }

    private func updateRustTerminalView(_ container: UnifiedTerminalContainerView) {
        guard let nsView = container.rustTerminalView else { return }
        nsView.setEventMonitoringEnabled(isActive && !isSuspended)

        let rustMetalActive = container.rustMetalCoordinator != nil
        if nsView.isHidden != isSuspended {
            nsView.isHidden = isSuspended
            if !isSuspended {
                nsView.needsDisplay = true
            }
        }

        // Suspend/resume Metal view alongside the terminal
        if rustMetalActive {
            container.rustMetalCoordinator?.metalView.isHidden = isSuspended
        }
        if nsView.notifyUpdateChanges == isSuspended {
            nsView.notifyUpdateChanges = !isSuspended
        }
        nsView.setCursorLineHighlightEnabled(false)
        nsView.configureCursorLineHighlight(contextLines: false, inputHistory: false)

        let desiredFont = terminalFont()
        let fontChanged = nsView.font.fontName != desiredFont.fontName || nsView.font.pointSize != desiredFont.pointSize
        if fontChanged {
            nsView.font = desiredFont
            container.rustMetalCoordinator?.fontChanged()
        }

        let scheme = settings.currentColorScheme
        nsView.applyColorScheme(scheme)

        // Notify Rust Metal coordinator only when the color scheme actually changes
        if rustMetalActive {
            let sig = scheme.signature
            if container.lastMetalColorSchemeSignature != sig {
                container.lastMetalColorSchemeSignature = sig
                container.rustMetalCoordinator?.colorSchemeChanged()
            }
        }

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
