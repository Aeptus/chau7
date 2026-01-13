// MARK: - IOSurface Direct Display Support
// Uses IOSurface for direct GPU-to-display path, bypassing the window server
// compositor for minimum possible display latency.

import Foundation
import IOSurface
import Metal
import CoreVideo
import QuartzCore

/// IOSurface-based renderer for direct GPU-to-display rendering.
/// Achieves lower latency than CAMetalLayer by avoiding compositor overhead.
public final class IOSurfaceRenderer {

    // MARK: - Types

    /// Surface configuration
    public struct SurfaceConfiguration {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let pixelFormat: OSType
        let useGPU: Bool

        public init(width: Int, height: Int, useGPU: Bool = true) {
            self.width = width
            self.height = height
            self.bytesPerRow = width * 4  // BGRA = 4 bytes per pixel
            self.pixelFormat = kCVPixelFormatType_32BGRA
            self.useGPU = useGPU
        }
    }

    // MARK: - Properties

    private var surface: IOSurface?
    private var metalTexture: MTLTexture?
    private let device: MTLDevice
    private let textureCache: CVMetalTextureCache?
    private var config: SurfaceConfiguration

    /// Whether the surface is currently locked for writing
    private var isLocked = false

    /// Statistics
    public private(set) var framesRendered: UInt64 = 0
    public private(set) var lastFrameTime: CFAbsoluteTime = 0

    // MARK: - Initialization

    public init?(device: MTLDevice, config: SurfaceConfiguration) {
        self.device = device
        self.config = config

        // Create texture cache for Metal integration
        var cache: CVMetalTextureCache?
        let cacheResult = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &cache
        )

        guard cacheResult == kCVReturnSuccess else {
            Log.error("IOSurfaceRenderer: Failed to create Metal texture cache")
            return nil
        }
        self.textureCache = cache

        // Create initial surface
        guard createSurface() else {
            return nil
        }
    }

    deinit {
        if isLocked, let surface = surface {
            IOSurfaceUnlock(surface, [], nil)
        }
    }

    // MARK: - Surface Management

    /// Creates a new IOSurface with the current configuration
    @discardableResult
    private func createSurface() -> Bool {
        let properties: [IOSurfacePropertyKey: Any] = [
            .width: config.width,
            .height: config.height,
            .bytesPerRow: config.bytesPerRow,
            .bytesPerElement: 4,
            .pixelFormat: config.pixelFormat,
            .allocSize: config.bytesPerRow * config.height,
            // Use GPU for hardware acceleration
            .cacheMode: config.useGPU ? IOSurfaceMemoryMap.writeCombine.rawValue : IOSurfaceMemoryMap.defaultCache.rawValue
        ]

        guard let newSurface = IOSurface(properties: properties) else {
            Log.error("IOSurfaceRenderer: Failed to create IOSurface")
            return false
        }

        self.surface = newSurface

        // Create Metal texture from the surface
        if config.useGPU {
            createMetalTexture()
        }

        Log.info("IOSurfaceRenderer: Created \(config.width)x\(config.height) surface")
        return true
    }

    /// Creates a Metal texture backed by the IOSurface
    private func createMetalTexture() {
        guard let surface = surface else { return }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: config.width,
            height: config.height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .managed

        // Create texture from IOSurface
        let texture = device.makeTexture(
            descriptor: descriptor,
            iosurface: surface,
            plane: 0
        )

        self.metalTexture = texture
    }

    /// Resizes the surface if needed
    public func resize(width: Int, height: Int) {
        guard width != config.width || height != config.height else { return }

        // Unlock if locked
        if isLocked, let surface = surface {
            IOSurfaceUnlock(surface, [], nil)
            isLocked = false
        }

        config = SurfaceConfiguration(width: width, height: height, useGPU: config.useGPU)
        createSurface()
    }

    // MARK: - CPU Rendering Path

    /// Locks the surface for CPU writing
    public func lockForCPUWrite() -> UnsafeMutableRawPointer? {
        guard let surface = surface, !isLocked else { return nil }

        let result = IOSurfaceLock(surface, [], nil)
        guard result == kIOReturnSuccess else {
            Log.error("IOSurfaceRenderer: Failed to lock surface: \(result)")
            return nil
        }

        isLocked = true
        return IOSurfaceGetBaseAddress(surface)
    }

    /// Unlocks the surface after CPU writing
    public func unlockFromCPUWrite() {
        guard let surface = surface, isLocked else { return }
        IOSurfaceUnlock(surface, [], nil)
        isLocked = false
    }

    /// Renders directly to the surface buffer (CPU path)
    public func renderCPU(_ renderBlock: (UnsafeMutableRawPointer, Int, Int, Int) -> Void) {
        guard let baseAddress = lockForCPUWrite() else { return }

        renderBlock(baseAddress, config.width, config.height, config.bytesPerRow)

        unlockFromCPUWrite()
        framesRendered += 1
        lastFrameTime = CFAbsoluteTimeGetCurrent()
    }

    // MARK: - GPU Rendering Path

    /// Gets the Metal texture for GPU rendering
    public var renderTarget: MTLTexture? {
        return metalTexture
    }

    /// Called after GPU rendering is complete
    public func didRenderGPU() {
        framesRendered += 1
        lastFrameTime = CFAbsoluteTimeGetCurrent()
    }

    // MARK: - Display Integration

    /// Gets the IOSurface for display
    public var displaySurface: IOSurface? {
        return surface
    }

    /// Gets the surface ID for cross-process sharing
    public var surfaceID: IOSurfaceID {
        guard let surface = surface else { return 0 }
        return IOSurfaceGetID(surface)
    }

    /// Attaches the surface to a CALayer for display
    public func attachToLayer(_ layer: CALayer) {
        guard let surface = surface else { return }
        layer.contents = surface
    }

    // MARK: - Double Buffering Support

    /// Surface pair for double buffering
    private var frontSurface: IOSurface?
    private var backSurface: IOSurface?
    private var frontTexture: MTLTexture?
    private var backTexture: MTLTexture?

    /// Enables double buffering for tear-free display
    public func enableDoubleBuffering() {
        // Create second surface
        let properties: [IOSurfacePropertyKey: Any] = [
            .width: config.width,
            .height: config.height,
            .bytesPerRow: config.bytesPerRow,
            .bytesPerElement: 4,
            .pixelFormat: config.pixelFormat,
            .allocSize: config.bytesPerRow * config.height
        ]

        guard let second = IOSurface(properties: properties) else {
            Log.error("IOSurfaceRenderer: Failed to create back buffer")
            return
        }

        frontSurface = surface
        frontTexture = metalTexture
        backSurface = second

        // Create back texture
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: config.width,
            height: config.height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .managed

        backTexture = device.makeTexture(
            descriptor: descriptor,
            iosurface: second,
            plane: 0
        )

        Log.info("IOSurfaceRenderer: Double buffering enabled")
    }

    /// Swaps front and back buffers
    public func swapBuffers() {
        swap(&frontSurface, &backSurface)
        swap(&frontTexture, &backTexture)
        surface = frontSurface
        metalTexture = frontTexture
    }

    /// Gets the back buffer for rendering
    public var backRenderTarget: MTLTexture? {
        return backTexture
    }
}

// MARK: - IOSurface Property Keys

extension IOSurfacePropertyKey {
    static let width = IOSurfacePropertyKey(rawValue: kIOSurfaceWidth as String)
    static let height = IOSurfacePropertyKey(rawValue: kIOSurfaceHeight as String)
    static let bytesPerRow = IOSurfacePropertyKey(rawValue: kIOSurfaceBytesPerRow as String)
    static let bytesPerElement = IOSurfacePropertyKey(rawValue: kIOSurfaceBytesPerElement as String)
    static let pixelFormat = IOSurfacePropertyKey(rawValue: kIOSurfacePixelFormat as String)
    static let allocSize = IOSurfacePropertyKey(rawValue: kIOSurfaceAllocSize as String)
    static let cacheMode = IOSurfacePropertyKey(rawValue: kIOSurfaceCacheMode as String)
}

// MARK: - IOSurface Memory Map Modes

enum IOSurfaceMemoryMap: UInt32 {
    case defaultCache = 0
    case inhibitCache = 1
    case writeThrough = 2
    case writeCombine = 3
}

// MARK: - Low-Latency Display Controller

/// Coordinates IOSurface rendering with display timing for minimum latency.
public final class LowLatencyDisplayController {

    private var displayLink: CVDisplayLink?
    private let renderer: IOSurfaceRenderer
    private var frameCallback: (() -> Void)?

    /// Current display latency in milliseconds
    public private(set) var displayLatency: Double = 0

    /// Target latency (used for adaptive rendering)
    public var targetLatency: Double = 8.33  // 120Hz = 8.33ms

    public init(renderer: IOSurfaceRenderer) {
        self.renderer = renderer
    }

    deinit {
        stop()
    }

    /// Starts synchronized rendering
    public func start(frameCallback: @escaping () -> Void) {
        self.frameCallback = frameCallback

        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)

        guard let displayLink = displayLink else {
            Log.error("LowLatencyDisplayController: Failed to create display link")
            return
        }

        let callback: CVDisplayLinkOutputCallback = { link, now, outputTime, flagsIn, flagsOut, context -> CVReturn in
            guard let context = context else { return kCVReturnSuccess }
            let controller = Unmanaged<LowLatencyDisplayController>.fromOpaque(context).takeUnretainedValue()
            controller.displayCallback(now: now, outputTime: outputTime)
            return kCVReturnSuccess
        }

        CVDisplayLinkSetOutputCallback(displayLink, callback, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(displayLink)

        Log.info("LowLatencyDisplayController: Started display-synchronized rendering")
    }

    /// Stops synchronized rendering
    public func stop() {
        if let displayLink = displayLink {
            CVDisplayLinkStop(displayLink)
            self.displayLink = nil
        }
    }

    private func displayCallback(now: UnsafePointer<CVTimeStamp>, outputTime: UnsafePointer<CVTimeStamp>) {
        let nowTime = Double(now.pointee.hostTime) / 1_000_000_000.0
        let outputTimeSec = Double(outputTime.pointee.hostTime) / 1_000_000_000.0

        // Calculate time until next VBlank
        displayLatency = (outputTimeSec - nowTime) * 1000.0  // ms

        // Dispatch frame callback
        DispatchQueue.main.async { [weak self] in
            self?.frameCallback?()
        }
    }

    /// Gets the refresh rate of the current display
    public var displayRefreshRate: Double {
        guard let displayLink = displayLink else { return 60.0 }

        let refreshPeriod = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(displayLink)

        // Check if the time is indefinite (flags bit 1 indicates indefinite)
        // kCVTimeIsIndefinite = 1 << 1 = 2
        if (refreshPeriod.flags & 2) != 0 {
            return 60.0
        }

        guard refreshPeriod.timeValue > 0 else { return 60.0 }
        return Double(refreshPeriod.timeScale) / Double(refreshPeriod.timeValue)
    }
}
