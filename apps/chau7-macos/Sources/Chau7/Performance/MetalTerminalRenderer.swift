// MARK: - Metal-Based Terminal Renderer
// GPU-accelerated rendering with dynamic glyph atlas, cursor, and decorations.
// Uses instanced rendering with on-demand glyph rasterization.

import Foundation
import MetalKit
import CoreText
import simd

// MARK: - simd_float4x4 Orthographic Extension

extension simd_float4x4 {
    init(orthographicLeft left: Float, right: Float, bottom: Float, top: Float, near: Float, far: Float) {
        self.init(columns: (
            SIMD4<Float>(2.0 / (right - left), 0, 0, 0),
            SIMD4<Float>(0, 2.0 / (top - bottom), 0, 0),
            SIMD4<Float>(0, 0, -2.0 / (far - near), 0),
            SIMD4<Float>(-(right + left) / (right - left),
                        -(top + bottom) / (top - bottom),
                        -(far + near) / (far - near),
                        1)
        ))
    }
}

/// Metal-based terminal renderer with GPU-accelerated text rendering.
/// Features:
/// - Dynamic glyph atlas with on-demand rasterization (Unicode, emoji, CJK)
/// - Bold/italic glyph variants via style-keyed cache
/// - Cursor rendering (block, underline, bar) with blink support
/// - Text decorations (underline, strikethrough) in fragment shader
/// - Retina/HiDPI scaling
public final class MetalTerminalRenderer: NSObject {

    // MARK: - Types

    /// Per-cell instance data uploaded to GPU each frame
    struct CellInstance {
        var position: SIMD2<Float>      // Screen position (x, y) in points
        var texCoord: SIMD4<Float>      // Glyph UV coords (u, v, width, height)
        var foreground: SIMD4<Float>    // Foreground color (RGBA)
        var background: SIMD4<Float>    // Background color (RGBA)
        var flags: UInt32               // Bold=1, italic=2, underline=4, strikethrough=8, blink=16
        var padding: UInt32 = 0         // Alignment padding
    }

    /// Glyph cache key: codepoint + style variant
    struct GlyphKey: Hashable {
        let codePoint: UInt32
        let bold: Bool
        let italic: Bool
    }

    /// Glyph information in the atlas
    struct GlyphInfo {
        let textureRect: CGRect     // UV coordinates in atlas
        let bearing: CGPoint        // Offset from baseline
        let advance: CGFloat        // Horizontal advance
        let isWide: Bool            // Double-width (CJK)
    }

    // MARK: - Metal Resources

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState!
    private var backgroundPipelineState: MTLRenderPipelineState!

    // Buffers
    private var instanceBuffer: MTLBuffer!
    private var uniformBuffer: MTLBuffer!
    private var vertexBuffer: MTLBuffer!
    private let maxCells = 50000

    // MARK: - Glyph Atlas (Dynamic)

    private var glyphAtlas: MTLTexture!
    private var atlasContext: CGContext!
    private var atlasWidth: Int = 2048
    private var atlasHeight: Int = 2048
    private var glyphCache: [GlyphKey: GlyphInfo] = [:]

    /// Packing cursor for the next glyph slot
    private var packX: CGFloat = 0
    private var packY: CGFloat = 0
    private var packRowHeight: CGFloat = 0

    /// Whether the atlas texture needs re-upload after new glyphs were rasterized
    private var atlasDirty = false

    /// Cache miss count for profiling
    private(set) var glyphCacheMisses: Int = 0

    // MARK: - Font

    private var regularFont: CTFont!
    private var boldFont: CTFont!
    private var italicFont: CTFont!
    private var boldItalicFont: CTFont!
    private var cellSize: CGSize = .zero
    private var fontAscent: CGFloat = 0
    private var fontDescent: CGFloat = 0
    private var fontSize: CGFloat = 13
    private var scaleFactor: CGFloat = 1.0

    // MARK: - Cursor State

    /// Set by the coordinator before each render call
    var cursorRow: Int = 0
    var cursorCol: Int = 0
    /// "block", "underline", or "bar"
    var cursorStyle: String = "block"
    var cursorVisible: Bool = true
    var cursorColor: SIMD4<Float> = SIMD4(1, 1, 1, 0.7)

    // MARK: - Blink State

    /// Current cursor blink phase (true = visible)
    var cursorBlinkPhase: Bool = true
    /// Whether cursor blink is enabled
    var cursorBlinkEnabled: Bool = true
    /// Current text blink phase (true = visible) — for cells with blink flag (bit 4)
    var textBlinkPhase: Bool = true
    /// Whether any cell in the current frame has the blink flag
    var hasBlinkingCells: Bool = false

    // Uniforms — include blinkVisible and scaleFactor for the fragment shader
    struct Uniforms {
        var projectionMatrix: simd_float4x4
        var atlasSize: SIMD2<Float>
        var cellSize: SIMD2<Float>
        var viewportSize: SIMD2<Float>
        var scaleFactor: Float
        var blinkVisible: Float  // 1.0 = show blinking text, 0.0 = hide
        var _pad: SIMD2<Float> = .zero  // alignment padding
    }

    // MARK: - Initialization

    public init?(device: MTLDevice? = nil) {
        guard let metalDevice = device ?? MTLCreateSystemDefaultDevice() else {
            Log.error("MetalRenderer: Failed to create Metal device")
            return nil
        }

        guard let queue = metalDevice.makeCommandQueue() else {
            Log.error("MetalRenderer: Failed to create command queue")
            return nil
        }

        self.device = metalDevice
        self.commandQueue = queue

        super.init()

        do {
            try setupPipelines()
            try setupBuffers()
            setupAtlasContext()
        } catch {
            Log.error("MetalRenderer: Setup failed: \(error)")
            return nil
        }
    }

    // MARK: - Setup

    private func setupPipelines() throws {
        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)

        guard let vertexFunction = library.makeFunction(name: "vertexShader"),
              let fragmentFunction = library.makeFunction(name: "fragmentShader"),
              let bgVertexFunction = library.makeFunction(name: "backgroundVertexShader"),
              let bgFragmentFunction = library.makeFunction(name: "backgroundFragmentShader") else {
            throw MetalError.shaderCompilationFailed
        }

        // Glyph pipeline with alpha blending
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)

        // Background pipeline (opaque)
        let bgDescriptor = MTLRenderPipelineDescriptor()
        bgDescriptor.vertexFunction = bgVertexFunction
        bgDescriptor.fragmentFunction = bgFragmentFunction
        bgDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        backgroundPipelineState = try device.makeRenderPipelineState(descriptor: bgDescriptor)
    }

    private func setupBuffers() throws {
        let instanceSize = MemoryLayout<CellInstance>.stride * maxCells
        guard let instBuffer = device.makeBuffer(length: instanceSize, options: .storageModeShared) else {
            throw MetalError.bufferAllocationFailed
        }
        instanceBuffer = instBuffer

        let uniformSize = MemoryLayout<Uniforms>.stride
        guard let uniBuffer = device.makeBuffer(length: uniformSize, options: .storageModeShared) else {
            throw MetalError.bufferAllocationFailed
        }
        uniformBuffer = uniBuffer

        let vertices: [SIMD2<Float>] = [
            SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1), SIMD2(1, 1),
        ]
        guard let vtxBuffer = device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared) else {
            throw MetalError.bufferAllocationFailed
        }
        vertexBuffer = vtxBuffer
    }

    /// Creates the CPU-side bitmap context for glyph rasterization.
    private func setupAtlasContext() {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        atlasContext = CGContext(
            data: nil,
            width: atlasWidth,
            height: atlasHeight,
            bitsPerComponent: 8,
            bytesPerRow: atlasWidth * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        atlasContext?.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0))
        atlasContext?.fill(CGRect(x: 0, y: 0, width: atlasWidth, height: atlasHeight))
    }

    // MARK: - Font Configuration

    /// Configures fonts and rebuilds the base glyph atlas for ASCII.
    /// Accepts an NSFont directly to avoid issues with private system font names
    /// (e.g. ".SFMono-Regular") that CTFontCreateWithName may not resolve correctly.
    public func setFont(nsFont: NSFont, scaleFactor: CGFloat = 1.0) {
        self.fontSize = nsFont.pointSize
        self.scaleFactor = scaleFactor

        // Scale font for Retina rasterization.
        // NSFont is toll-free bridged to CTFont on macOS, so we can cast directly
        // and then create a scaled copy. This preserves the exact font identity
        // including private system fonts like .SFMono-Regular.
        let scaledSize = nsFont.pointSize * scaleFactor
        let baseCTFont = nsFont as CTFont
        regularFont = CTFontCreateCopyWithAttributes(baseCTFont, scaledSize, nil, nil)

        // Derive bold, italic, bold+italic variants
        let boldTraits: CTFontSymbolicTraits = .boldTrait
        let italicTraits: CTFontSymbolicTraits = .italicTrait
        let boldItalicTraits: CTFontSymbolicTraits = [.boldTrait, .italicTrait]

        boldFont = CTFontCreateCopyWithSymbolicTraits(regularFont, scaledSize, nil, boldTraits, boldTraits)
            ?? regularFont
        italicFont = CTFontCreateCopyWithSymbolicTraits(regularFont, scaledSize, nil, italicTraits, italicTraits)
            ?? regularFont
        boldItalicFont = CTFontCreateCopyWithSymbolicTraits(regularFont, scaledSize, nil, boldItalicTraits, boldItalicTraits)
            ?? regularFont

        // Cell size from regular font metrics — must match the CPU renderer
        // (RustTerminalView.updateCellDimensions) so rows/cols agree.
        let ascent = CTFontGetAscent(regularFont)
        let descent = CTFontGetDescent(regularFont)
        let leading = CTFontGetLeading(regularFont)
        self.fontAscent = ascent
        self.fontDescent = descent

        // Width: max advance of all printable ASCII (32-126), not just "M"
        var characters = (32...126).map { UniChar($0) }
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        CTFontGetGlyphsForCharacters(regularFont, &characters, &glyphs, characters.count)
        var advances = [CGSize](repeating: .zero, count: characters.count)
        CTFontGetAdvancesForGlyphs(regularFont, .horizontal, glyphs, &advances, glyphs.count)
        var maxWidth: CGFloat = 0
        for i in 0..<glyphs.count where glyphs[i] != 0 {
            maxWidth = max(maxWidth, advances[i].width)
        }
        // Fallback if no glyphs mapped
        if maxWidth == 0 {
            var mGlyph = CTFontGetGlyphWithName(regularFont, "M" as CFString)
            var mAdvance = CGSize.zero
            CTFontGetAdvancesForGlyphs(regularFont, .horizontal, &mGlyph, &mAdvance, 1)
            maxWidth = mAdvance.width
        }

        cellSize = CGSize(
            width: ceil(maxWidth),
            height: ceil(ascent + descent + leading)
        )

        Log.info("MetalRenderer: Font configured — \(CTFontCopyFullName(regularFont)), scaledSize=\(scaledSize), cellSize=\(cellSize), ascent=\(ascent), descent=\(descent)")

        // Guard against zero cell size (would make nothing visible)
        guard cellSize.width > 0 && cellSize.height > 0 else {
            Log.error("MetalRenderer: Zero cell size from font \(CTFontCopyFullName(regularFont))")
            return
        }

        // Reset atlas and rebuild for ASCII baseline
        resetAtlas()
        prerasterizeASCII()
        uploadAtlasTexture()
        Log.info("MetalRenderer: Atlas populated with \(glyphCache.count) glyphs")
    }

    /// Clears glyph atlas and cache, resetting the packing cursor.
    private func resetAtlas() {
        glyphCache.removeAll()
        packX = 0
        packY = 0
        packRowHeight = 0
        atlasDirty = false

        // Clear bitmap
        atlasContext?.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0))
        atlasContext?.fill(CGRect(x: 0, y: 0, width: atlasWidth, height: atlasHeight))
    }

    /// Pre-rasterizes ASCII 32-126 for all style variants (regular, bold, italic, bold+italic).
    private func prerasterizeASCII() {
        let styles: [(bold: Bool, italic: Bool)] = [
            (false, false), (true, false), (false, true), (true, true)
        ]
        for style in styles {
            for cp: UInt32 in 32...126 {
                _ = rasterizeGlyph(codePoint: cp, bold: style.bold, italic: style.italic)
            }
        }
    }

    // MARK: - Dynamic Glyph Rasterization

    /// Rasterizes a single glyph into the atlas. Returns the GlyphInfo, or nil if atlas is full.
    @discardableResult
    private func rasterizeGlyph(codePoint: UInt32, bold: Bool, italic: Bool) -> GlyphInfo? {
        let key = GlyphKey(codePoint: codePoint, bold: bold, italic: italic)
        if let existing = glyphCache[key] { return existing }

        guard let context = atlasContext else { return nil }

        let font: CTFont
        switch (bold, italic) {
        case (true, true): font = boldItalicFont
        case (true, false): font = boldFont
        case (false, true): font = italicFont
        case (false, false): font = regularFont
        }

        guard let scalar = Unicode.Scalar(codePoint) else { return nil }
        let charStr = String(Character(scalar))
        var unichars = [UniChar](charStr.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: unichars.count)
        CTFontGetGlyphsForCharacters(font, &unichars, &glyphs, unichars.count)

        // Determine if this is a wide character
        var advanceSize = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, &advanceSize, 1)
        let isWide = advanceSize.width > cellSize.width * 1.3

        let slotWidth = isWide ? cellSize.width * 2 : cellSize.width
        let slotHeight = cellSize.height
        let padding: CGFloat = 2

        // Advance packing cursor
        if packX + slotWidth + padding > CGFloat(atlasWidth) {
            packX = 0
            packY += packRowHeight + padding
            packRowHeight = 0
        }

        // Check if atlas is full — recover by clearing and rebuilding
        if packY + slotHeight > CGFloat(atlasHeight) {
            Log.warn("MetalRenderer: Glyph atlas full, resetting and rebuilding ASCII baseline")
            resetAtlas()
            prerasterizeASCII()
            uploadAtlasTexture()
            // Re-check after reset — the glyph we want should now fit
            if packY + slotHeight > CGFloat(atlasHeight) {
                Log.error("MetalRenderer: Atlas still full after reset, cannot rasterize U+\(String(codePoint, radix: 16))")
                return nil
            }
        }

        packRowHeight = max(packRowHeight, slotHeight)

        // Draw glyph into atlas bitmap.
        // CTFontDrawGlyphs positions glyphs at the baseline. We place the
        // baseline at a fixed offset within each slot: descent from the slot's
        // bottom edge (equivalently, ascent below the slot's top edge).
        // In CG coordinates (origin bottom-left, Y up):
        //   slot bottom = atlasHeight - packY - slotHeight
        //   baseline    = slot bottom + fontDescent
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        var boundingRect = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .horizontal, glyphs, &boundingRect, 1)
        let baselineY = CGFloat(atlasHeight) - packY - slotHeight + fontDescent
        var position = CGPoint(x: packX, y: baselineY)
        CTFontDrawGlyphs(font, glyphs, &position, 1, context)

        // UV coordinates (normalized).
        // CGContext has origin at bottom-left but bitmap data is stored top-down.
        // Metal texture y=0 is the top row. The glyph slot at packY occupies
        // Metal texture y from packY/atlasHeight to (packY+slotHeight)/atlasHeight.
        let texRect = CGRect(
            x: packX / CGFloat(atlasWidth),
            y: packY / CGFloat(atlasHeight),
            width: slotWidth / CGFloat(atlasWidth),
            height: slotHeight / CGFloat(atlasHeight)
        )

        let info = GlyphInfo(
            textureRect: texRect,
            bearing: CGPoint(x: boundingRect.origin.x, y: boundingRect.origin.y),
            advance: slotWidth,
            isWide: isWide
        )
        glyphCache[key] = info

        packX += slotWidth + padding
        atlasDirty = true
        return info
    }

    /// Uploads the CPU bitmap to the GPU texture.
    private func uploadAtlasTexture() {
        guard let data = atlasContext?.data else { return }

        if glyphAtlas == nil {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: atlasWidth,
                height: atlasHeight,
                mipmapped: false
            )
            desc.usage = [.shaderRead]
            glyphAtlas = device.makeTexture(descriptor: desc)
        }

        glyphAtlas?.replace(
            region: MTLRegionMake2D(0, 0, atlasWidth, atlasHeight),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: atlasWidth * 4
        )
        atlasDirty = false
    }

    /// Looks up a glyph, rasterizing on-demand if needed. Returns space glyph as fallback.
    private func lookupGlyph(codePoint: UInt32, bold: Bool, italic: Bool) -> GlyphInfo? {
        let key = GlyphKey(codePoint: codePoint, bold: bold, italic: italic)
        if let info = glyphCache[key] { return info }

        // Cache miss — rasterize on demand
        glyphCacheMisses += 1
        if let info = rasterizeGlyph(codePoint: codePoint, bold: bold, italic: italic) {
            return info
        }

        // Fallback: try regular style
        let fallbackKey = GlyphKey(codePoint: codePoint, bold: false, italic: false)
        if let info = glyphCache[fallbackKey] { return info }
        if let info = rasterizeGlyph(codePoint: codePoint, bold: false, italic: false) {
            return info
        }

        // Ultimate fallback: space
        return glyphCache[GlyphKey(codePoint: 0x20, bold: false, italic: false)]
    }

    // MARK: - Rendering

    /// Renders terminal cells to the given drawable.
    public func render(
        cells: UnsafeBufferPointer<TerminalCell>,
        rows: Int,
        cols: Int,
        to drawable: CAMetalDrawable,
        viewportSize: CGSize
    ) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let cellCount = min(cells.count, maxCells)

        // Update instance buffer (may trigger on-demand glyph rasterization)
        updateInstanceBuffer(cells: cells, count: cellCount, cols: cols)

        // Upload atlas if new glyphs were rasterized
        if atlasDirty { uploadAtlasTexture() }

        updateUniforms(viewportSize: viewportSize)

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = drawable.texture
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].storeAction = .store
        passDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.1, 0.1, 0.1, 1.0)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else { return }

        // Pass 1: Backgrounds
        encoder.setRenderPipelineState(backgroundPipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 1)
        encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 2)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: cellCount)

        // Pass 2: Glyphs + decorations (flags handled in fragment shader)
        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(glyphAtlas, index: 0)
        encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 2)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: cellCount)

        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func updateInstanceBuffer(cells: UnsafeBufferPointer<TerminalCell>, count: Int, cols: Int) {
        let instances = instanceBuffer.contents().bindMemory(to: CellInstance.self, capacity: count)
        // Cell size in points (not scaled — scaling happens in the atlas and texture UVs)
        let cw = Float(cellSize.width / scaleFactor)
        let ch = Float(cellSize.height / scaleFactor)

        var foundBlinkingCells = false

        for i in 0..<count {
            let cell = cells[i]
            let row = i / cols
            let col = i % cols

            let isBold = (cell.flags & 1) != 0
            let isItalic = (cell.flags & 2) != 0

            // Track if any cell has the blink flag (bit 4)
            if (cell.flags & 16) != 0 {
                foundBlinkingCells = true
            }

            let glyphInfo = lookupGlyph(codePoint: cell.character, bold: isBold, italic: isItalic)

            let texCoord: SIMD4<Float>
            if let info = glyphInfo {
                texCoord = SIMD4(
                    Float(info.textureRect.origin.x),
                    Float(info.textureRect.origin.y),
                    Float(info.textureRect.width),
                    Float(info.textureRect.height)
                )
            } else {
                texCoord = SIMD4(0, 0, 0, 0)
            }

            instances[i] = CellInstance(
                position: SIMD2(Float(col) * cw, Float(row) * ch),
                texCoord: texCoord,
                foreground: cell.foregroundColor,
                background: cell.backgroundColor,
                flags: cell.flags
            )
        }

        hasBlinkingCells = foundBlinkingCells

        // Cursor: overwrite the cursor cell's flags to signal the shader
        // Only show cursor when blink phase is on (or blink is disabled)
        let showCursor = cursorVisible && (!cursorBlinkEnabled || cursorBlinkPhase)
        if showCursor && cols > 0 {
            let cursorIndex = cursorRow * cols + cursorCol
            if cursorIndex >= 0 && cursorIndex < count {
                // Encode cursor type in upper bits: bit 5=cursor present, bits 6-7=style
                var flags = instances[cursorIndex].flags | (1 << 5) // cursor present
                switch cursorStyle {
                case "underline": flags |= (1 << 6)
                case "bar": flags |= (2 << 6)
                default: break // block = 0 in bits 6-7
                }
                instances[cursorIndex].flags = flags
                // Use cursor color for the foreground in cursor mode
                instances[cursorIndex].foreground = cursorColor
            }
        }
    }

    private func updateUniforms(viewportSize: CGSize) {
        let uniforms = uniformBuffer.contents().bindMemory(to: Uniforms.self, capacity: 1)

        let projectionMatrix = simd_float4x4(
            orthographicLeft: 0,
            right: Float(viewportSize.width),
            bottom: Float(viewportSize.height),
            top: 0,
            near: -1,
            far: 1
        )

        uniforms.pointee = Uniforms(
            projectionMatrix: projectionMatrix,
            atlasSize: SIMD2(Float(atlasWidth), Float(atlasHeight)),
            cellSize: SIMD2(Float(cellSize.width / scaleFactor), Float(cellSize.height / scaleFactor)),
            viewportSize: SIMD2(Float(viewportSize.width), Float(viewportSize.height)),
            scaleFactor: Float(scaleFactor),
            blinkVisible: textBlinkPhase ? 1.0 : 0.0
        )
    }

    // MARK: - Error Types

    enum MetalError: Error {
        case deviceNotFound
        case shaderCompilationFailed
        case pipelineCreationFailed
        case bufferAllocationFailed
    }
}

// MARK: - Terminal Cell Type

/// Represents a single terminal cell for GPU rendering
public struct TerminalCell {
    public var character: UInt32
    public var foregroundColor: SIMD4<Float>
    public var backgroundColor: SIMD4<Float>
    /// Bold=1, italic=2, underline=4, strikethrough=8, blink=16
    /// Cursor bits (set by renderer): cursor_present=32, cursor_style in bits 6-7
    public var flags: UInt32

    public init(character: UInt32 = 0x20,
                foreground: SIMD4<Float> = SIMD4(1, 1, 1, 1),
                background: SIMD4<Float> = SIMD4(0, 0, 0, 1),
                flags: UInt32 = 0) {
        self.character = character
        self.foregroundColor = foreground
        self.backgroundColor = background
        self.flags = flags
    }
}

// MARK: - Shader Source

extension MetalTerminalRenderer {
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct CellInstance {
        float2 position;
        float4 texCoord;  // u, v, width, height
        float4 foreground;
        float4 background;
        uint flags;
        uint padding;
    };

    struct Uniforms {
        float4x4 projectionMatrix;
        float2 atlasSize;
        float2 cellSize;
        float2 viewportSize;
        float scaleFactor;
        float blinkVisible;  // 1.0 = show blinking text, 0.0 = hide
        float2 _pad;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 texCoord;
        float2 cellLocalPos;  // 0..1 within the cell (for decorations)
        float4 foreground;
        float4 background;
        uint flags;
    };

    // Background vertex shader
    vertex VertexOut backgroundVertexShader(
        uint vertexID [[vertex_id]],
        uint instanceID [[instance_id]],
        constant float2* vertices [[buffer(0)]],
        constant CellInstance* instances [[buffer(1)]],
        constant Uniforms& uniforms [[buffer(2)]]
    ) {
        CellInstance instance = instances[instanceID];
        float2 vertexPos = vertices[vertexID];
        float2 position = instance.position + vertexPos * uniforms.cellSize;

        VertexOut out;
        out.position = uniforms.projectionMatrix * float4(position, 0.0, 1.0);
        out.texCoord = float2(0);
        out.cellLocalPos = vertexPos;
        out.foreground = instance.foreground;
        out.background = instance.background;
        out.flags = instance.flags;
        return out;
    }

    fragment float4 backgroundFragmentShader(VertexOut in [[stage_in]]) {
        // Cursor: block style fills the entire cell with foreground color
        bool hasCursor = (in.flags & (1u << 5)) != 0;
        uint cursorStyle = (in.flags >> 6) & 3u;
        if (hasCursor && cursorStyle == 0) {
            // Block cursor: fill cell with cursor/foreground color
            return in.foreground;
        }
        return in.background;
    }

    // Glyph vertex shader
    vertex VertexOut vertexShader(
        uint vertexID [[vertex_id]],
        uint instanceID [[instance_id]],
        constant float2* vertices [[buffer(0)]],
        constant CellInstance* instances [[buffer(1)]],
        constant Uniforms& uniforms [[buffer(2)]]
    ) {
        CellInstance instance = instances[instanceID];
        float2 vertexPos = vertices[vertexID];
        float2 position = instance.position + vertexPos * uniforms.cellSize;
        float2 texCoord = instance.texCoord.xy + vertexPos * instance.texCoord.zw;

        VertexOut out;
        out.position = uniforms.projectionMatrix * float4(position, 0.0, 1.0);
        out.texCoord = texCoord;
        out.cellLocalPos = vertexPos;
        out.foreground = instance.foreground;
        out.background = instance.background;
        out.flags = instance.flags;
        return out;
    }

    fragment float4 fragmentShader(
        VertexOut in [[stage_in]],
        texture2d<float> glyphAtlas [[texture(0)]],
        constant Uniforms& uniforms [[buffer(2)]]
    ) {
        constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
        float4 texColor = glyphAtlas.sample(textureSampler, in.texCoord);

        // Text blink: hide text when blink flag (bit 4) is set and blink phase is off
        bool isBlink = (in.flags & 16u) != 0;
        if (isBlink && uniforms.blinkVisible < 0.5) {
            return float4(0, 0, 0, 0); // transparent — shows background only
        }

        // Base glyph color
        float4 color = float4(in.foreground.rgb, texColor.a * in.foreground.a);

        // Cursor handling
        bool hasCursor = (in.flags & (1u << 5)) != 0;
        uint cursorStyle = (in.flags >> 6) & 3u;
        if (hasCursor) {
            if (cursorStyle == 0) {
                // Block cursor: invert text color against cursor bg
                color = float4(in.background.rgb, texColor.a);
            } else if (cursorStyle == 1) {
                // Underline cursor: draw a line at the bottom
                if (in.cellLocalPos.y > 0.9) {
                    return in.foreground;
                }
            } else if (cursorStyle == 2) {
                // Bar cursor: draw a thin line on the left
                if (in.cellLocalPos.x < 0.08) {
                    return in.foreground;
                }
            }
        }

        // Decoration thickness scaled for Retina: ~2 device pixels
        float thickness = 2.0 / (uniforms.cellSize.y * uniforms.scaleFactor);

        // Underline decoration (bit 2) — variant in bits 8-10
        // 0/1=single, 2=double, 3=curl/wavy, 4=dotted, 5=dashed
        if ((in.flags & 4u) != 0) {
            uint ulVariant = (in.flags >> 8) & 7u;
            float underlineY = 1.0 - 0.12; // ~88% from top

            if (ulVariant == 2u) {
                // Double underline: two thin lines separated by a gap
                float gap = thickness * 1.5;
                float line1Y = underlineY;
                float line2Y = underlineY + thickness + gap;
                bool onLine1 = (in.cellLocalPos.y > line1Y && in.cellLocalPos.y < line1Y + thickness);
                bool onLine2 = (in.cellLocalPos.y > line2Y && in.cellLocalPos.y < line2Y + thickness);
                if (onLine1 || onLine2) {
                    return float4(in.foreground.rgb, 1.0);
                }
            } else if (ulVariant == 3u) {
                // Curl/wavy underline: sine wave
                float amplitude = thickness * 2.0;
                float freq = 3.14159 * 4.0; // ~2 full waves per cell
                float wave = underlineY + amplitude * sin(in.cellLocalPos.x * freq);
                float dist = abs(in.cellLocalPos.y - wave);
                if (dist < thickness) {
                    return float4(in.foreground.rgb, 1.0);
                }
            } else if (ulVariant == 4u) {
                // Dotted underline: alternating dots
                bool onY = (in.cellLocalPos.y > underlineY && in.cellLocalPos.y < underlineY + thickness);
                float dotPeriod = 0.08; // width of each dot+gap cycle
                bool onDot = fmod(in.cellLocalPos.x, dotPeriod) < (dotPeriod * 0.5);
                if (onY && onDot) {
                    return float4(in.foreground.rgb, 1.0);
                }
            } else if (ulVariant == 5u) {
                // Dashed underline: longer dashes with gaps
                bool onY = (in.cellLocalPos.y > underlineY && in.cellLocalPos.y < underlineY + thickness);
                float dashPeriod = 0.2; // width of each dash+gap cycle
                bool onDash = fmod(in.cellLocalPos.x, dashPeriod) < (dashPeriod * 0.7);
                if (onY && onDash) {
                    return float4(in.foreground.rgb, 1.0);
                }
            } else {
                // Single underline (variant 0 or 1): solid line
                if (in.cellLocalPos.y > underlineY && in.cellLocalPos.y < underlineY + thickness) {
                    return float4(in.foreground.rgb, 1.0);
                }
            }
        }

        // Strikethrough decoration (bit 3) — positioned at vertical center
        if ((in.flags & 8u) != 0) {
            float strikeY = 0.5 - thickness / 2.0;
            if (in.cellLocalPos.y > strikeY && in.cellLocalPos.y < strikeY + thickness) {
                return float4(in.foreground.rgb, 1.0);
            }
        }

        return color;
    }
    """
}
