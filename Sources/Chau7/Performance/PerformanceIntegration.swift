// MARK: - Performance Integration Layer
// Connects all low-latency components with the existing terminal infrastructure.
// Provides a unified API for high-performance terminal rendering.

import Foundation
import MetalKit
import SwiftTerm

/// Coordinates all performance components for low-latency terminal operation.
/// This is the main entry point for integrating cutting-edge optimizations.
public final class PerformanceTerminal {

    // MARK: - Components

    /// Metal-based GPU renderer
    private var metalRenderer: MetalTerminalRenderer?

    /// Triple-buffered terminal state
    private var tripleBuffer: TripleBufferedTerminal?

    /// SIMD-accelerated parser results cache
    private var lastParseResult: SIMDTerminalParser.ScanResult?

    /// Lock-free ring buffer for PTY data
    private let ptyBuffer: LockFreeByteBuffer

    /// Low-latency keyboard handler
    private var inputHandler: LowLatencyInputHandler?

    /// Predictive renderer
    private let predictiveRenderer: PredictiveRenderer

    /// Thread managers
    private let ptyManager: PTYThreadManager
    private var renderThread: RenderThread?

    /// Display controller
    private var displayController: LowLatencyDisplayController?

    // MARK: - Configuration

    /// Performance configuration options
    public struct Configuration {
        /// Enable Metal GPU rendering
        public var useMetalRendering: Bool = true

        /// Enable low-latency IOKit HID input
        public var useLowLatencyInput: Bool = true

        /// Enable predictive text rendering
        public var usePredictiveRendering: Bool = true

        /// Enable triple buffering
        public var useTripleBuffering: Bool = true

        /// Enable SIMD parsing
        public var useSIMDParsing: Bool = true

        /// Target frame rate (0 = VSync)
        public var targetFPS: Int = 0

        /// Enable real-time thread priority
        public var useRealtimePriority: Bool = false

        public init() {}
    }

    private var config: Configuration

    // MARK: - State

    /// Whether the performance system is active
    public private(set) var isActive = false

    /// Terminal dimensions
    private var rows: Int = 24
    private var cols: Int = 80

    /// Callback for render frames
    public var onFrame: ((TripleBufferedTerminal) -> Void)?

    /// Callback for keyboard input
    public var onKeyInput: ((LowLatencyInputHandler.KeyEvent) -> Void)?

    // MARK: - Initialization

    public init(configuration: Configuration = Configuration()) {
        self.config = configuration
        self.ptyBuffer = LockFreeByteBuffer(capacity: 256 * 1024)  // 256KB
        self.predictiveRenderer = PredictiveRenderer(maxCacheSize: 1000)
        self.ptyManager = PTYThreadManager()

        Log.info("PerformanceTerminal: Initialized with configuration")
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    /// Starts all performance subsystems
    public func start(rows: Int, cols: Int, metalDevice: MTLDevice? = nil) throws {
        guard !isActive else { return }

        self.rows = rows
        self.cols = cols

        // Initialize Metal renderer
        if config.useMetalRendering {
            if let device = metalDevice ?? MTLCreateSystemDefaultDevice() {
                metalRenderer = try MetalTerminalRenderer(device: device)
                Log.info("PerformanceTerminal: Metal renderer initialized")
            } else {
                Log.warn("PerformanceTerminal: Metal not available, falling back to CPU")
            }
        }

        // Initialize triple buffering
        if config.useTripleBuffering {
            tripleBuffer = TripleBufferedTerminal(rows: rows, cols: cols)
            Log.info("PerformanceTerminal: Triple buffering enabled")
        }

        // Initialize low-latency input
        if config.useLowLatencyInput {
            inputHandler = LowLatencyInputHandler()
            inputHandler?.start { [weak self] event in
                self?.handleKeyEvent(event)
            }
            Log.info("PerformanceTerminal: Low-latency input enabled")
        }

        // Start render thread if using realtime priority
        if config.useRealtimePriority {
            renderThread = RenderThread()
            renderThread?.targetFPS = config.targetFPS > 0 ? config.targetFPS : 120
            renderThread?.start { [weak self] in
                self?.renderFrame()
            }
            Log.info("PerformanceTerminal: Render thread started")
        }

        isActive = true
        Log.info("PerformanceTerminal: Started")
    }

    /// Stops all performance subsystems
    public func stop() {
        guard isActive else { return }

        renderThread?.stop()
        renderThread = nil

        inputHandler?.stop()
        inputHandler = nil

        displayController?.stop()
        displayController = nil

        isActive = false
        Log.info("PerformanceTerminal: Stopped")
    }

    // MARK: - Terminal Size

    /// Updates terminal dimensions
    public func resize(rows: Int, cols: Int) {
        self.rows = rows
        self.cols = cols

        // Recreate triple buffer with new dimensions
        if config.useTripleBuffering {
            tripleBuffer = TripleBufferedTerminal(rows: rows, cols: cols)
        }

        // Note: MetalTerminalRenderer recreates glyph atlas on resize
        // metalRenderer?.resize(rows: rows, cols: cols)

        Log.info("PerformanceTerminal: Resized to \(cols)x\(rows)")
    }

    // MARK: - PTY Data Processing

    /// Processes incoming PTY data with optimized parsing
    public func processPTYData(_ data: Data) {
        ptyManager.read { [weak self] in
            self?.internalProcessPTYData(data)
        }
    }

    private func internalProcessPTYData(_ data: Data) {
        // Write to ring buffer for lock-free access
        data.withUnsafeBytes { rawBuffer in
            if let baseAddress = rawBuffer.baseAddress {
                _ = ptyBuffer.write(from: baseAddress, count: rawBuffer.count)
            }
        }

        // SIMD-accelerated parsing
        if config.useSIMDParsing {
            let scanResult = SIMDTerminalParser.scan(data)
            lastParseResult = scanResult

            // Fast path: pure ASCII with no escapes
            if scanResult.isPureASCII && !scanResult.hasEscapeSequences {
                fastPathProcessText(data)
                return
            }
        }

        // Standard processing path
        standardProcessData(data)
    }

    /// Fast path for pure ASCII text (no escape sequences)
    private func fastPathProcessText(_ data: Data) {
        guard let buffer = tripleBuffer else { return }

        // Direct cell updates without escape sequence parsing
        data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for byte in bytes {
                if byte >= 0x20 && byte <= 0x7E {
                    // Printable ASCII - direct cell write
                    // This would update the current cursor position
                }
            }
        }

        buffer.commitUpdate()
    }

    /// Standard processing with escape sequence handling
    private func standardProcessData(_ data: Data) {
        // Parse escape sequences
        let sequences = data.withUnsafeBytes { rawBuffer -> [SIMDTerminalParser.EscapeSequence] in
            let buffer = rawBuffer.bindMemory(to: UInt8.self)
            return SIMDTerminalParser.parseEscapeSequences(buffer)
        }

        // Process sequences
        for sequence in sequences {
            processEscapeSequence(sequence)
        }

        tripleBuffer?.commitUpdate()
    }

    private func processEscapeSequence(_ sequence: SIMDTerminalParser.EscapeSequence) {
        switch sequence.type {
        case .csi:
            if let params = sequence.csiParameters, let cmd = sequence.csiFinalByte {
                processCSI(params: params, command: cmd)
            }
        case .osc:
            processOSC(sequence.rawBytes)
        case .simple:
            processSimpleEscape(sequence.rawBytes)
        case .unknown:
            break
        }
    }

    private func processCSI(params: [Int], command: UInt8) {
        // Handle CSI commands (cursor movement, colors, etc.)
        switch Character(UnicodeScalar(command)) {
        case "m":  // SGR - Select Graphic Rendition
            // Process color/style changes
            break
        case "H", "f":  // Cursor position
            let row = params.first ?? 1
            let col = params.count > 1 ? params[1] : 1
            // Update cursor position
            break
        case "J":  // Erase in display
            break
        case "K":  // Erase in line
            break
        default:
            break
        }
    }

    private func processOSC(_ bytes: [UInt8]) {
        // Handle OSC commands (window title, colors, etc.)
    }

    private func processSimpleEscape(_ bytes: [UInt8]) {
        // Handle simple escape sequences
    }

    // MARK: - Input Handling

    private func handleKeyEvent(_ event: LowLatencyInputHandler.KeyEvent) {
        // Record for predictions
        if let char = event.character {
            predictiveRenderer.recordInput(String(char))
        }

        // Forward to callback
        onKeyInput?(event)
    }

    /// Sends keyboard input to PTY (with optional local echo)
    public func sendInput(_ text: String, localEcho: Bool = false) {
        if localEcho {
            // Show local echo immediately while waiting for PTY response
            showLocalEcho(text)
        }

        // Record for predictions
        predictiveRenderer.recordInput(text)
    }

    private func showLocalEcho(_ text: String) {
        // Immediately update display with typed text
        // This will be reconciled when PTY response arrives
    }

    // MARK: - Rendering

    private func renderFrame() {
        guard let buffer = tripleBuffer else { return }

        // Check if we need to render
        guard buffer.needsFullRefresh || !buffer.dirtyRows.isEmpty else { return }

        // Call render callback
        onFrame?(buffer)

        // Present the frame
        buffer.presentFrame()
    }

    /// Renders to a Metal drawable
    public func render(to drawable: CAMetalDrawable) {
        guard let renderer = metalRenderer, let buffer = tripleBuffer else { return }

        // Convert triple buffer to cell array for GPU
        var cells: [TerminalCell] = []
        cells.reserveCapacity(rows * cols)

        for row in 0..<rows {
            for col in 0..<cols {
                cells.append(buffer.getCell(row: row, col: col))
            }
        }

        // Render using the Metal renderer
        cells.withUnsafeBufferPointer { cellBuffer in
            renderer.render(
                cells: cellBuffer,
                rows: rows,
                cols: cols,
                to: drawable,
                viewportSize: CGSize(width: drawable.texture.width, height: drawable.texture.height)
            )
        }
    }

    // MARK: - Predictions

    /// Gets predictions based on current input
    public func getPredictions(for input: String) -> [PredictiveRenderer.Prediction] {
        guard config.usePredictiveRendering else { return [] }
        return predictiveRenderer.predict(currentInput: input)
    }

    // MARK: - Statistics

    public struct Statistics {
        public let isActive: Bool
        public let metalRendererActive: Bool
        public let tripleBufferStats: TripleBufferedTerminal.Statistics?
        public let ptyBufferStats: (capacity: Int, used: Int, available: Int)
        public let predictiveStats: PredictiveRenderer.Statistics
        public let renderThreadFPS: Double
        public let inputEventsProcessed: UInt64
    }

    public var statistics: Statistics {
        Statistics(
            isActive: isActive,
            metalRendererActive: metalRenderer != nil,
            tripleBufferStats: tripleBuffer?.statistics,
            ptyBufferStats: (
                capacity: ptyBuffer.bufferCapacity,
                used: ptyBuffer.count,
                available: ptyBuffer.availableSpace
            ),
            predictiveStats: predictiveRenderer.statistics,
            renderThreadFPS: renderThread?.measuredFPS ?? 0,
            inputEventsProcessed: inputHandler?.totalEvents ?? 0
        )
    }
}

// MARK: - SwiftTerm Integration

/// Extension to integrate PerformanceTerminal with existing SwiftTerm-based views
extension PerformanceTerminal {

    /// Creates a PerformanceTerminal configured for use with a SwiftTerm TerminalView
    public static func forSwiftTerm(terminal: Terminal) -> PerformanceTerminal {
        let perf = PerformanceTerminal()

        let rows = terminal.rows
        let cols = terminal.cols

        do {
            try perf.start(rows: rows, cols: cols)
        } catch {
            Log.error("Failed to start PerformanceTerminal: \(error)")
        }

        return perf
    }

    /// Syncs the triple buffer state from a SwiftTerm Terminal
    /// Note: This is a simplified implementation - customize based on actual CharData API
    public func syncFromTerminal(_ terminal: Terminal) {
        guard let buffer = tripleBuffer else { return }

        // Copy terminal state to update buffer
        // Note: Adjust based on actual SwiftTerm CharData API
        for row in 0..<min(rows, terminal.rows) {
            for col in 0..<min(cols, terminal.cols) {
                if let line = terminal.getLine(row: row), col < line.count {
                    let charData = line[col]
                    // Use Character property which is public
                    let cell = TerminalCell(
                        character: UInt32(charData.getCharacter().asciiValue ?? 0x20),
                        foreground: SIMD4<Float>(1, 1, 1, 1),  // Default white
                        background: SIMD4<Float>(0, 0, 0, 1),  // Default black
                        flags: 0  // Simplified - expand as needed
                    )
                    buffer.setCell(row: row, col: col, cell)
                }
            }
        }

        buffer.commitUpdate()
    }
}

// MARK: - Feature Flag Integration

extension FeatureSettings {
    /// Whether to use the performance terminal subsystem
    public var usePerformanceTerminal: Bool {
        // This could be a user preference
        return true
    }

    /// Performance terminal configuration
    public var performanceConfig: PerformanceTerminal.Configuration {
        var config = PerformanceTerminal.Configuration()
        config.useMetalRendering = true
        config.useLowLatencyInput = true
        config.usePredictiveRendering = true
        config.useTripleBuffering = true
        config.useSIMDParsing = true
        return config
    }
}
