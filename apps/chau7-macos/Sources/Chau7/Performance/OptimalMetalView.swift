// MARK: - Optimal Metal View Configuration

// Configures CAMetalLayer and MTKView for minimum display latency.

import Foundation
import MetalKit
import QuartzCore

/// High-performance Metal view with optimal display settings.
/// Configures CAMetalLayer for minimal input-to-display latency.
final class OptimalMetalView: MTKView {

    // MARK: - Configuration Options

    /// Display timing mode
    enum TimingMode {
        /// Sync to display refresh (VSync on)
        case vsync
        /// Render as fast as possible (VSync off, may tear)
        case immediate
        /// Adaptive sync (VRR displays)
        case adaptive
    }

    /// Frame pacing strategy
    enum FramePacing {
        /// Let the system decide (displaySyncEnabled = true)
        case system
        /// Manual frame pacing with CVDisplayLink
        case displayLink
        /// Manual pacing with target framerate
        case targetFramerate(fps: Int)
    }

    // MARK: - Properties

    private var displayLink: CVDisplayLink?
    private var frameCallback: (() -> Void)?
    private var timingMode: TimingMode = .vsync
    private var framePacing: FramePacing = .system

    /// Measured time between frames (for adaptive pacing)
    private(set) var frameTime: Double = 0
    private var lastFrameTimestamp: CFAbsoluteTime = 0

    /// Statistics
    private(set) var droppedFrames: UInt64 = 0
    private(set) var totalFrames: UInt64 = 0

    // MARK: - Initialization

    /// When true, all mouse events pass through to the view underneath.
    /// Used so the terminal view underneath handles input while Metal handles display.
    var isEventPassthrough = false

    init(frame: CGRect, device: MTLDevice) {
        super.init(frame: frame, device: device)
        configureForLowLatency()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        configureForLowLatency()
    }

    // MARK: - Event Passthrough

    override func hitTest(_ point: NSPoint) -> NSView? {
        if isEventPassthrough { return nil }
        return super.hitTest(point)
    }

    deinit {
        stopDisplayLink()
    }

    // MARK: - Configuration

    /// Configures the view and layer for minimum latency
    private func configureForLowLatency() {
        guard let metalLayer = layer as? CAMetalLayer else { return }

        // Use the Metal device
        if let device = MTLCreateSystemDefaultDevice() {
            self.device = device
            metalLayer.device = device
        }

        // === Critical Latency Settings ===

        // 1. Triple buffering (3 drawables in flight)
        //    Reduces frame stalls when GPU can't keep up
        metalLayer.maximumDrawableCount = 3

        // 2. Display sync - sync to VBlank
        //    Prevents tearing but adds ~1 frame of latency
        metalLayer.displaySyncEnabled = true

        // 3. Drawable presentation mode
        //    .direct = lowest latency but may tear on some displays
        //    We use displaySyncEnabled instead for reliable sync
        metalLayer.allowsNextDrawableTimeout = true

        // 4. Pixel format - use native display format
        metalLayer.pixelFormat = .bgra8Unorm

        // 5. Frame buffer only mode - skip depth/stencil for 2D
        metalLayer.framebufferOnly = true

        // 6. Disable automatic color management for speed
        metalLayer.wantsExtendedDynamicRangeContent = false
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)

        // 7. Contentsscale for Retina
        if let screen = NSScreen.main {
            metalLayer.contentsScale = screen.backingScaleFactor
        }

        // === MTKView Settings ===

        // Enable explicit drawing (we control when to render)
        enableSetNeedsDisplay = false
        isPaused = true // We'll use our own render loop

        // Prefer background drawing for responsiveness
        presentsWithTransaction = false

        // Clear color (terminal background)
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        // Sample count (no MSAA for speed)
        sampleCount = 1

        // Depth/stencil (disabled for 2D terminal)
        depthStencilPixelFormat = .invalid

        Log.trace("OptimalMetalView: Configured for low-latency rendering")
    }

    // MARK: - Timing Mode

    /// Sets the display timing mode
    func setTimingMode(_ mode: TimingMode) {
        guard let metalLayer = layer as? CAMetalLayer else { return }
        timingMode = mode

        switch mode {
        case .vsync:
            metalLayer.displaySyncEnabled = true
        case .immediate:
            metalLayer.displaySyncEnabled = false
        case .adaptive:
            // Adaptive uses displaySyncEnabled but with manual frame pacing
            metalLayer.displaySyncEnabled = true
        }
    }

    /// Sets the frame pacing strategy
    func setFramePacing(_ pacing: FramePacing) {
        framePacing = pacing

        switch pacing {
        case .system:
            stopDisplayLink()
            isPaused = true
            enableSetNeedsDisplay = false

        case .displayLink:
            isPaused = true
            enableSetNeedsDisplay = false
            startDisplayLink()

        case .targetFramerate(let fps):
            stopDisplayLink()
            isPaused = false
            preferredFramesPerSecond = fps
        }
    }

    // MARK: - Display Link

    /// Starts CVDisplayLink for manual frame pacing
    private func startDisplayLink() {
        guard displayLink == nil else { return }

        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)

        guard let displayLink = displayLink else {
            Log.error("OptimalMetalView: Failed to create CVDisplayLink")
            return
        }

        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, displayLinkContext -> CVReturn in
            guard let context = displayLinkContext else { return kCVReturnSuccess }
            let view = Unmanaged<OptimalMetalView>.fromOpaque(context).takeUnretainedValue()
            view.displayLinkFired()
            return kCVReturnSuccess
        }

        CVDisplayLinkSetOutputCallback(displayLink, callback, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(displayLink)

        Log.info("OptimalMetalView: Started CVDisplayLink")
    }

    /// Stops CVDisplayLink
    private func stopDisplayLink() {
        guard let displayLink = displayLink else { return }
        CVDisplayLinkStop(displayLink)
        self.displayLink = nil
        Log.info("OptimalMetalView: Stopped CVDisplayLink")
    }

    /// Called by CVDisplayLink on each VSync
    private func displayLinkFired() {
        let now = CFAbsoluteTimeGetCurrent()
        if lastFrameTimestamp > 0 {
            frameTime = now - lastFrameTimestamp
        }
        lastFrameTimestamp = now
        totalFrames += 1

        DispatchQueue.main.async { [weak self] in
            self?.frameCallback?()
        }
    }

    /// Sets the callback invoked on each display link tick
    func setFrameCallback(_ callback: @escaping () -> Void) {
        frameCallback = callback
    }

    // MARK: - Rendering

    /// Requests an immediate frame render (bypass display sync)
    func renderImmediately() {
        guard let metalLayer = layer as? CAMetalLayer else { return }

        // Temporarily disable sync for immediate render
        let wasSync = metalLayer.displaySyncEnabled
        metalLayer.displaySyncEnabled = false

        draw()

        metalLayer.displaySyncEnabled = wasSync
    }

    /// Gets the next drawable with timeout (non-blocking option)
    func nextDrawable(timeout: TimeInterval = 1.0) -> CAMetalDrawable? {
        guard let metalLayer = layer as? CAMetalLayer else { return nil }

        // Use allowsNextDrawableTimeout for non-blocking
        let previousTimeout = metalLayer.allowsNextDrawableTimeout
        metalLayer.allowsNextDrawableTimeout = timeout > 0

        let drawable = metalLayer.nextDrawable()

        if drawable == nil {
            droppedFrames += 1
            Log.warn("OptimalMetalView: Failed to acquire drawable (dropped frame)")
        }

        metalLayer.allowsNextDrawableTimeout = previousTimeout
        return drawable
    }

    // MARK: - Adaptive Frame Rate

    /// Calculates optimal frame rate based on display capabilities
    var optimalFrameRate: Int {
        guard let screen = window?.screen ?? NSScreen.main else {
            return 60
        }

        // Get display refresh rate
        if let refreshRate = screen.maximumFramesPerSecond {
            return refreshRate
        }

        // Fallback: check for ProMotion/120Hz displays
        if #available(macOS 12.0, *) {
            return screen.maximumFramesPerSecond ?? 60
        }

        return 60
    }

    // MARK: - Statistics

    struct FrameStatistics {
        let totalFrames: UInt64
        let droppedFrames: UInt64
        let averageFrameTime: Double
        let frameDropRate: Double
    }

    var statistics: FrameStatistics {
        let dropRate = totalFrames > 0 ? Double(droppedFrames) / Double(totalFrames) : 0
        return FrameStatistics(
            totalFrames: totalFrames,
            droppedFrames: droppedFrames,
            averageFrameTime: frameTime,
            frameDropRate: dropRate
        )
    }

    func resetStatistics() {
        totalFrames = 0
        droppedFrames = 0
        frameTime = 0
        lastFrameTimestamp = 0
    }
}

// MARK: - NSScreen Extension

extension NSScreen {
    /// Maximum frames per second for this display
    var maximumFramesPerSecond: Int? {
        guard let displayID = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }

        guard let mode = CGDisplayCopyDisplayMode(displayID) else {
            return nil
        }

        let refreshRate = mode.refreshRate
        return refreshRate > 0 ? Int(refreshRate) : nil
    }
}

// MARK: - Layer-Backed Configuration

/// Extension for configuring any NSView with Metal layer for terminal rendering
extension NSView {
    /// Configures this view to use an optimal CAMetalLayer
    @discardableResult
    func configureMetalLayer(device: MTLDevice) -> CAMetalLayer? {
        wantsLayer = true

        let metalLayer = CAMetalLayer()
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.maximumDrawableCount = 3
        metalLayer.displaySyncEnabled = true

        if let screen = window?.screen ?? NSScreen.main {
            metalLayer.contentsScale = screen.backingScaleFactor
        }

        layer = metalLayer
        return metalLayer
    }
}
