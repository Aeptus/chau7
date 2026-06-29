// MARK: - Optimal Metal View Configuration

// Configures CAMetalLayer and MTKView for minimum display latency.
//
// Deliberately small: an earlier revision carried an unused frame-pacing API
// (CVDisplayLink callbacks with an Unmanaged self that could race deinit, a
// renderImmediately() that toggled displaySyncEnabled around a draw, and a
// nextDrawable(timeout:) whose timeout was ignored). None of it had a
// production caller, and each was a hazard waiting for one — removed.

import Foundation
import MetalKit
import QuartzCore

/// High-performance Metal view with optimal display settings.
/// Configures CAMetalLayer for minimal input-to-display latency.
final class OptimalMetalView: MTKView {

    /// When true, all mouse events pass through to the view underneath.
    /// Used so the terminal view underneath handles input while Metal handles display.
    var isEventPassthrough = false

    /// Fires when the view's backing properties (Retina scale, color space)
    /// change — e.g. the window moves between a Retina and a non-Retina
    /// display. The owner must reconfigure font/atlas scale and redraw, or
    /// glyphs render at the previous display's scale (blurry/oversampled)
    /// until the next tab switch.
    var onBackingPropertiesChanged: (() -> Void)?

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

    // MARK: - Display Changes

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // Track the window's actual screen — the init-time seed uses
        // NSScreen.main, which may not be where the window ends up.
        if let scale = window?.backingScaleFactor,
           let metalLayer = layer as? CAMetalLayer,
           metalLayer.contentsScale != scale {
            metalLayer.contentsScale = scale
        }
        onBackingPropertiesChanged?()
    }

    // MARK: - Configuration

    /// Configures the view and layer for minimum latency
    private func configureForLowLatency() {
        guard let metalLayer = layer as? CAMetalLayer else { return }

        // Keep the device passed to `init(frame:device:)` so the view's
        // CAMetalLayer matches the renderer command queue. Coder-based init
        // has no explicit device, so fall back only there.
        if device == nil {
            device = MTLCreateSystemDefaultDevice()
        }
        metalLayer.device = device

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

        // Async presentation keeps the last frame in the layer's backing store.
        presentsWithTransaction = false

        // Clear color (terminal background)
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        // Sample count (no MSAA for speed)
        sampleCount = 1

        // Depth/stencil (disabled for 2D terminal)
        depthStencilPixelFormat = .invalid

        Log.trace("OptimalMetalView: Configured for low-latency rendering")
    }
}
