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
            SIMD4<Float>(
                -(right + left) / (right - left),
                -(top + bottom) / (top - bottom),
                -(far + near) / (far - near),
                1
            )
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
        var position: SIMD2<Float> // Screen position (x, y) in points
        var texCoord: SIMD4<Float> // Glyph UV coords (u, v, width, height)
        var foreground: SIMD4<Float> // Foreground color (RGBA)
        var background: SIMD4<Float> // Background color (RGBA)
        var flags: UInt32 // Bold=1, italic=2, underline=4, strikethrough=8, blink=16
        var padding: UInt32 = 0 // Alignment padding
    }

    /// Glyph cache key: codepoint + style variant
    struct GlyphKey: Hashable {
        let codePoint: UInt32
        let bold: Bool
        let italic: Bool
    }

    /// Ligature cache key: multi-character sequence + style
    struct LigatureKey: Hashable {
        let sequence: String
        let bold: Bool
        let italic: Bool
    }

    /// Glyph information in the atlas
    struct GlyphInfo {
        let textureRect: CGRect // UV coordinates in atlas
        let bearing: CGPoint // Offset from baseline
        let advance: CGFloat // Horizontal advance
        let isWide: Bool // Double-width (CJK)
    }

    /// Ligature information: a multi-cell glyph in the atlas
    struct LigatureInfo {
        let textureRect: CGRect // UV coordinates in atlas
        let cellSpan: Int // Number of terminal cells this ligature spans
    }

    // MARK: - Shared Pipeline Cache (compiled once, reused across tabs)

    private static var cachedLibrary: MTLLibrary?
    private static var cachedPipeline: MTLRenderPipelineState?
    private static var cachedBgPipeline: MTLRenderPipelineState?

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
    private var atlasWidth = 2048
    private var atlasHeight = 2048
    private var glyphCache: [GlyphKey: GlyphInfo] = [:]
    /// Cache for multi-character ligature glyphs. nil value = font doesn't form a ligature.
    private var ligatureCache: [LigatureKey: LigatureInfo?] = [:]
    /// Whether ligature rendering is enabled (set from FeatureSettings)
    var ligaturesEnabled = false

    /// Packing cursor for the next glyph slot
    private var packX: CGFloat = 0
    private var packY: CGFloat = 0
    private var packRowHeight: CGFloat = 0

    /// Whether the atlas texture needs re-upload after new glyphs were rasterized
    private var atlasDirty = false

    /// Cache miss count for profiling
    private(set) var glyphCacheMisses = 0

    /// Diagnostic frame counter for throttled logging
    private var diagFrameCounter = 0

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
    /// Normalized underline position within a cell (0=top, 1=bottom), derived from font metrics
    private var underlinePosition: Float = 0.88

    // MARK: - Cursor State

    /// Set by the coordinator before each render call
    var cursorRow = 0
    var cursorCol = 0
    /// "block", "underline", or "bar"
    var cursorStyle = "block"
    var cursorVisible = true
    var cursorColor: SIMD4<Float> = SIMD4(1, 1, 1, 0.7)

    // MARK: - Blink State

    /// Current cursor blink phase (true = visible)
    var cursorBlinkPhase = true
    /// Whether cursor blink is enabled
    var cursorBlinkEnabled = true
    /// Current text blink phase (true = visible) — for cells with blink flag (bit 4)
    var textBlinkPhase = true
    /// Whether any cell in the current frame has the blink flag
    var hasBlinkingCells = false

    /// Uniforms — include blinkVisible and scaleFactor for the fragment shader
    struct Uniforms {
        var projectionMatrix: simd_float4x4
        var atlasSize: SIMD2<Float>
        var cellSize: SIMD2<Float>
        var viewportSize: SIMD2<Float>
        var scaleFactor: Float
        var blinkVisible: Float // 1.0 = show blinking text, 0.0 = hide
        var underlineY: Float // normalized Y position for underline (0=top, 1=bottom)
        var _pad: Float = 0 // alignment padding
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
        if let cached = Self.cachedPipeline, let cachedBg = Self.cachedBgPipeline {
            pipelineState = cached
            backgroundPipelineState = cachedBg
            return
        }

        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        Self.cachedLibrary = library

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

        Self.cachedPipeline = pipelineState
        Self.cachedBgPipeline = backgroundPipelineState
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
            SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1), SIMD2(1, 1)
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
        atlasContext?.clear(CGRect(x: 0, y: 0, width: atlasWidth, height: atlasHeight))

        // Font smoothing note: setShouldSmoothFonts is NOT used here because
        // subpixel LCD smoothing puts per-channel coverage in R/G/B, but our shader
        // only reads texColor.a — inflating alpha and destroying edge antialiasing.
        // Grayscale AA + subpixel positioning gives the best atlas quality.
        atlasContext?.setShouldSmoothFonts(false)
        atlasContext?.setShouldAntialias(true)
        atlasContext?.setAllowsFontSubpixelPositioning(true)
        atlasContext?.setShouldSubpixelPositionFonts(true)
    }

    // MARK: - Font Configuration

    /// Configures fonts and rebuilds the base glyph atlas for ASCII.
    /// Accepts an NSFont directly to avoid issues with private system font names
    /// (e.g. ".SFMono-Regular") that CTFontCreateWithName may not resolve correctly.
    public func setFont(nsFont: NSFont, scaleFactor: CGFloat = 1.0) {
        fontSize = nsFont.pointSize
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

        // Compute cell size in point space using the shared algorithm (single source of truth),
        // then scale for atlas rendering. Positions divide by scaleFactor to recover
        // the exact CPU cell dimensions, eliminating rounding drift.
        let pointCellSize = TerminalFont.cellSize(for: nsFont)
        cellSize = CGSize(
            width: pointCellSize.width * scaleFactor,
            height: pointCellSize.height * scaleFactor
        )

        // Store scaled font metrics for glyph placement within atlas slots
        let ascent = CTFontGetAscent(regularFont)
        let descent = CTFontGetDescent(regularFont)
        fontAscent = ascent
        fontDescent = descent

        // Derive underline position from font metrics (in normalized cell space).
        // CTFontGetUnderlinePosition returns a negative offset below the baseline.
        // In cell space: baseline is at (ascent / cellHeight_pt), underline is below that.
        let baseCT = nsFont as CTFont
        let ptAscent = CTFontGetAscent(baseCT)
        let ulOffset = CTFontGetUnderlinePosition(baseCT) // negative, e.g. -1.5
        let baselineFrac = ptAscent / pointCellSize.height // e.g. 0.82
        let ulFrac = baselineFrac - ulOffset / pointCellSize.height // e.g. 0.82 + 1.5/17 ≈ 0.91
        underlinePosition = Float(min(max(ulFrac, 0.7), 0.95))

        Log.info("MetalRenderer: Font configured — \(CTFontCopyFullName(regularFont)), scaledSize=\(scaledSize), cellSize=\(cellSize), ascent=\(ascent), descent=\(descent)")

        // Guard against zero cell size (would make nothing visible)
        guard cellSize.width > 0, cellSize.height > 0 else {
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

        // Clear bitmap — must use .clear() not .fill() with transparent black.
        // CGContext defaults to source-over compositing where fill(0,0,0,0)
        // is a no-op: src*0 + dst*1 = dst. Only .clear() forces all bytes to zero.
        atlasContext?.clear(CGRect(x: 0, y: 0, width: atlasWidth, height: atlasHeight))
    }

    /// Pre-rasterizes ASCII 32-126 for all style variants (regular, bold, italic, bold+italic).
    private func prerasterizeASCII() {
        let styles: [(bold: Bool, italic: Bool)] = [
            (false, false), (true, false), (false, true), (true, true)
        ]
        for style in styles {
            for cp: UInt32 in 32 ... 126 {
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

        // Try the primary font first
        var drawFont = font
        let found = CTFontGetGlyphsForCharacters(font, &unichars, &glyphs, unichars.count)

        // Font cascade fallback: if the primary font doesn't have this glyph
        // (returns false or glyph ID 0 / .notdef), ask CoreText to find a font that does.
        // This is what CTLine does automatically in the CPU renderer — we replicate
        // it here so box-drawing chars (U+2500–U+257F), emoji, and other symbols render.
        //
        // Note: CTFontGetGlyphsForCharacters returns false if ANY character couldn't be
        // mapped. We also check glyph[0]==0 for the single-char case.
        if !found || glyphs[0] == 0 {
            let fallback = CTFontCreateForString(font, charStr as CFString, CFRangeMake(0, charStr.utf16.count))
            CTFontGetGlyphsForCharacters(fallback, &unichars, &glyphs, unichars.count)
            if glyphs[0] != 0 {
                drawFont = fallback
            }
        }

        // Diagnostic: log box-drawing glyph resolution (trace-only)
        let isBoxDraw = codePoint >= 0x2500 && codePoint <= 0x257F
        if isBoxDraw && Log.isTraceEnabled {
            let fontName = CTFontCopyPostScriptName(drawFont) as String
            Log.trace("[DIAG-SWIFT] rasterizeGlyph U+\(String(codePoint, radix: 16, uppercase: true)) '\(charStr)' found=\(found) glyph=\(glyphs[0]) font=\(fontName) bold=\(bold)")
        }

        // Determine if this is a wide character
        var advanceSize = CGSize.zero
        CTFontGetAdvancesForGlyphs(drawFont, .horizontal, &glyphs, &advanceSize, 1)
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
        CTFontGetBoundingRectsForGlyphs(drawFont, .horizontal, glyphs, &boundingRect, 1)
        let baselineY = CGFloat(atlasHeight) - packY - slotHeight + fontDescent
        var position = CGPoint(x: packX, y: baselineY)
        CTFontDrawGlyphs(drawFont, glyphs, &position, 1, context)

        // Diagnostic: check if box-drawing glyph produced visible pixels (trace-only)
        if isBoxDraw, Log.isTraceEnabled, let data = context.data {
            let bytesPerRow = context.bytesPerRow
            let slotRowStart = Int(packY)
            let slotRowEnd = min(Int(packY + slotHeight), atlasHeight)
            let slotColStart = Int(packX)
            let slotColEnd = min(Int(packX + slotWidth), atlasWidth)

            var nonZeroAlpha = 0
            var totalPixels = 0
            let ptr = data.bindMemory(to: UInt8.self, capacity: atlasHeight * bytesPerRow)
            for row in slotRowStart ..< slotRowEnd {
                for col in slotColStart ..< slotColEnd {
                    let offset = row * bytesPerRow + col * 4
                    let alpha = ptr[offset + 3]
                    if alpha > 0 { nonZeroAlpha += 1 }
                    totalPixels += 1
                }
            }
            Log
                .trace(
                    "[DIAG-SWIFT] rasterizeGlyph U+\(String(codePoint, radix: 16, uppercase: true)) pixelCheck: \(nonZeroAlpha)/\(totalPixels) non-zero alpha, slot=(\(slotColStart),\(slotRowStart))-(\(slotColEnd),\(slotRowEnd)), baseline=\(baselineY), packY=\(packY)"
                )

            dumpAtlasToPNG()
        }

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

    /// Debug: dump the atlas bitmap to a PNG file for visual inspection.
    /// Call after rasterizing all needed glyphs.
    private var atlasDumpCount = 0
    func dumpAtlasToPNG() {
        guard let context = atlasContext else { return }
        guard let image = context.makeImage() else { return }
        atlasDumpCount += 1
        let url = URL(fileURLWithPath: "/tmp/chau7_atlas_\(atlasDumpCount).png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        Log.trace("[DIAG-SWIFT] Dumped glyph atlas to \(url.path) (\(atlasWidth)x\(atlasHeight))")
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

    // MARK: - Ligature Rendering

    /// Try to form a ligature from consecutive cells. Returns nil if the font doesn't
    /// produce a ligature for this sequence (glyph count == char count = no substitution).
    func lookupLigature(sequence: String, bold: Bool, italic: Bool) -> LigatureInfo? {
        let key = LigatureKey(sequence: sequence, bold: bold, italic: italic)
        if let cached = ligatureCache[key] { return cached }

        // Ask CoreText to shape the sequence. If the resulting glyph count is less
        // than the character count, the font's GSUB table formed a ligature.
        let font: CTFont
        switch (bold, italic) {
        case (true, true): font = boldItalicFont
        case (true, false): font = boldFont
        case (false, true): font = italicFont
        case (false, false): font = regularFont
        }

        let attrString = NSAttributedString(
            string: sequence,
            attributes: [.font: font]
        )
        let line = CTLineCreateWithAttributedString(attrString)
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        guard let run = runs.first else {
            ligatureCache[key] = nil
            return nil
        }

        let glyphCount = CTRunGetGlyphCount(run)
        let charCount = sequence.count

        // If glyph count equals char count, no ligature was formed
        if glyphCount >= charCount {
            ligatureCache[key] = nil
            return nil
        }

        // Ligature formed! Rasterize the combined glyph into the atlas.
        let cellSpan = charCount
        let slotWidth = cellSize.width * CGFloat(cellSpan)
        let slotHeight = cellSize.height
        let padding: CGFloat = 2

        // Check atlas space
        if packX + slotWidth + padding > CGFloat(atlasWidth) {
            packX = 0
            packY += packRowHeight + padding
            packRowHeight = 0
        }
        if packY + slotHeight > CGFloat(atlasHeight) {
            // Atlas full — skip ligature
            ligatureCache[key] = nil
            return nil
        }
        packRowHeight = max(packRowHeight, slotHeight)

        // Draw the ligature sequence into the atlas bitmap
        guard let context = atlasContext else {
            ligatureCache[key] = nil
            return nil
        }
        let baselineY = CGFloat(atlasHeight) - packY - slotHeight + fontDescent
        let origin = CGPoint(x: packX, y: baselineY)

        context.saveGState()
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))

        // Use CTLineDraw to render the shaped sequence with ligatures
        context.textPosition = origin
        CTLineDraw(line, context)
        context.restoreGState()

        let texRect = CGRect(
            x: packX / CGFloat(atlasWidth),
            y: packY / CGFloat(atlasHeight),
            width: slotWidth / CGFloat(atlasWidth),
            height: slotHeight / CGFloat(atlasHeight)
        )

        let info = LigatureInfo(textureRect: texRect, cellSpan: cellSpan)
        ligatureCache[key] = info
        packX += slotWidth + padding
        atlasDirty = true
        return info
    }

    /// Maximum lookahead for ligature detection (3-char sequences like ===, !==)
    private static let maxLigatureLength = 3

    /// Try to form a ligature from consecutive cells starting at index.
    /// Returns nil if no ligature is formed or if the cells cross a row boundary.
    private func tryLigature(
        cells: UnsafeBufferPointer<TerminalCell>,
        index: Int, count: Int, cols: Int,
        bold: Bool, italic: Bool
    ) -> LigatureInfo? {
        let col = index % cols
        let maxLen = min(Self.maxLigatureLength, cols - col, count - index)
        guard maxLen >= 2 else { return nil }

        // Try longest sequence first (3-char, then 2-char)
        for len in stride(from: maxLen, through: 2, by: -1) {
            // All cells in the sequence must be printable ASCII with the same style
            var sequence = ""
            var valid = true
            for j in 0..<len {
                let c = cells[index + j]
                guard c.character >= 0x21, c.character < 0x7F,
                      let scalar = Unicode.Scalar(c.character) else {
                    valid = false
                    break
                }
                // Check same bold/italic style
                let cBold = (c.flags & 1) != 0
                let cItalic = (c.flags & 2) != 0
                if cBold != bold || cItalic != italic { valid = false; break }
                sequence.append(Character(scalar))
            }
            guard valid else { continue }

            if let info = lookupLigature(sequence: sequence, bold: bold, italic: italic) {
                return info
            }
        }
        return nil
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
        var ligatureSkip = 0 // Remaining cells in current ligature
        var ligatureRect = CGRect.zero // Atlas rect of current ligature
        var ligatureSpan = 0 // Total cell span of current ligature
        var ligatureSlice = 0 // Next slice index for continuation cells
        var boxDrawCount = 0 // Diagnostic counter
        let traceBoxDraw = Log.isTraceEnabled && diagFrameCounter.isMultiple(of: 600)

        for i in 0 ..< count {
            let cell = cells[i]
            let row = i / cols
            let col = i % cols

            let isBold = (cell.flags & 1) != 0
            let isItalic = (cell.flags & 2) != 0

            // Track if any cell has the blink flag (bit 4)
            if (cell.flags & 16) != 0 {
                foundBlinkingCells = true
            }

            // Count box-drawing chars reaching Metal (diagnostic details trace-only)
            if cell.character >= 0x2500, cell.character <= 0x257F {
                boxDrawCount += 1
                if traceBoxDraw, cell.character != 0x2500 || boxDrawCount == 1, boxDrawCount <= 3 {
                    let fg = cell.foregroundColor
                    let bg = cell.backgroundColor
                    let ch = Unicode.Scalar(cell.character).map { String(Character($0)) } ?? "?"
                    Log
                        .trace(
                            "[DIAG-SWIFT] box-draw: '\(ch)' U+\(String(cell.character, radix: 16)) at (\(row),\(col)) fg=(\(String(format: "%.2f", fg.x)),\(String(format: "%.2f", fg.y)),\(String(format: "%.2f", fg.z))) bg=(\(String(format: "%.2f", bg.x)),\(String(format: "%.2f", bg.y)),\(String(format: "%.2f", bg.z)))"
                        )
                }
            }

            // Ligature lookahead: try to form multi-char ligatures from consecutive cells.
            // When a ligature is found, its atlas texture is split across consecutive cells
            // (each cell gets its horizontal slice) so no shader changes are needed.
            var texCoord: SIMD4<Float> = SIMD4(0, 0, 0, 0)

            if ligaturesEnabled, cell.character >= 0x21, cell.character < 0x7F,
               ligatureSkip <= 0 {
                let ligInfo = tryLigature(cells: cells, index: i, count: count, cols: cols,
                                          bold: isBold, italic: isItalic)
                if let lig = ligInfo {
                    // First cell gets the left slice of the ligature texture.
                    // Subsequent cells (via ligatureSkip) get their slices below.
                    let sliceWidth = Float(lig.textureRect.width) / Float(lig.cellSpan)
                    texCoord = SIMD4(
                        Float(lig.textureRect.origin.x),
                        Float(lig.textureRect.origin.y),
                        sliceWidth,
                        Float(lig.textureRect.height)
                    )
                    ligatureSkip = lig.cellSpan - 1
                    ligatureRect = lig.textureRect
                    ligatureSpan = lig.cellSpan
                    ligatureSlice = 1 // next cell gets slice index 1
                }
            }

            if ligatureSkip > 0, texCoord == SIMD4(0, 0, 0, 0) {
                // This cell is a continuation of a ligature — render its slice
                let sliceWidth = Float(ligatureRect.width) / Float(ligatureSpan)
                texCoord = SIMD4(
                    Float(ligatureRect.origin.x) + sliceWidth * Float(ligatureSlice),
                    Float(ligatureRect.origin.y),
                    sliceWidth,
                    Float(ligatureRect.height)
                )
                ligatureSlice += 1
                ligatureSkip -= 1
            } else if texCoord == SIMD4(0, 0, 0, 0) {
                // Normal single-glyph path
                let glyphInfo = lookupGlyph(codePoint: cell.character, bold: isBold, italic: isItalic)
                if let info = glyphInfo {
                    texCoord = SIMD4(
                        Float(info.textureRect.origin.x),
                        Float(info.textureRect.origin.y),
                        Float(info.textureRect.width),
                        Float(info.textureRect.height)
                    )
                }
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

        // Diagnostic: log box-drawing count (trace-only, throttled to ~1/sec at 60fps)
        if boxDrawCount > 0 {
            diagFrameCounter += 1
            if Log.isTraceEnabled, diagFrameCounter % 300 == 1 {
                Log.trace("[DIAG-SWIFT] updateInstanceBuffer: \(boxDrawCount) box-drawing cells in frame (\(count) total cells, \(cols) cols)")
            }
        }

        // Cursor: overwrite the cursor cell's flags to signal the shader
        // Only show cursor when blink phase is on (or blink is disabled)
        let showCursor = cursorVisible && (!cursorBlinkEnabled || cursorBlinkPhase)
        if showCursor, cols > 0 {
            let cursorIndex = cursorRow * cols + cursorCol
            if cursorIndex >= 0, cursorIndex < count {
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
            blinkVisible: textBlinkPhase ? 1.0 : 0.0,
            underlineY: underlinePosition
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

    public init(
        character: UInt32 = 0x20,
        foreground: SIMD4<Float> = SIMD4(1, 1, 1, 1),
        background: SIMD4<Float> = SIMD4(0, 0, 0, 1),
        flags: UInt32 = 0
    ) {
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
        float underlineY;    // normalized Y position for underline decoration
        float _pad;
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
            float underlineY = uniforms.underlineY; // from font metrics

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
