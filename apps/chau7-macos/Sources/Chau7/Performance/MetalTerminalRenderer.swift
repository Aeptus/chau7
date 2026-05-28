// MARK: - Metal-Based Terminal Renderer

// GPU-accelerated rendering with dynamic glyph atlas, cursor, and decorations.
// Uses instanced rendering with on-demand glyph rasterization.

import Foundation
import MetalKit
import CoreText
import simd
import Chau7Core

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
final class MetalTerminalRenderer: NSObject {

    // MARK: - Types

    /// Per-cell instance data uploaded to GPU each frame
    struct CellInstance {
        var position: SIMD2<Float> // Screen position (x, y) in points
        var texCoord: SIMD4<Float> // Glyph UV coords (u, v, width, height)
        var foreground: SIMD4<Float> // Foreground color (RGBA)
        var background: SIMD4<Float> // Background color (RGBA)
        var cursorColor: SIMD4<Float> // Cursor fill/decorator color (RGBA)
        var flags: UInt32 // Bold=1, italic=2, underline=4, strikethrough=8, blink=16
        var padding: UInt32 = 0 // Alignment padding
    }

    /// Glyph cache key: grapheme cluster bytes + style variant.
    ///
    /// Multi-codepoint clusters (ZWJ emoji, regional indicators, VS16, combining marks)
    /// hash to a single atlas slot, so the same `👨🏽‍💻` cluster is shaped once and
    /// reused. ASCII clusters are single-byte Data values and incur no per-cluster
    /// allocation thanks to Data's inline storage.
    struct GlyphKey: Hashable {
        let cluster: Data
        let bold: Bool
        let italic: Bool
    }

    // `GlyphInfo` extended to know whether its atlas slot stores RGBA color data
    // (Apple Color Emoji, sbix/COLR/CBDT) or a monochrome alpha mask. Fragment
    // shader branches on this via the `colorGlyphFlag` bit in the instance flags.

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
        let isColor: Bool // True for color bitmap glyphs (emoji); false for mono alpha mask
    }

    /// Ligature information: a multi-cell glyph in the atlas
    struct LigatureInfo {
        let textureRect: CGRect // UV coordinates in atlas
        let cellSpan: Int // Number of terminal cells this ligature spans
    }

    private struct CursorRenderState: Equatable {
        let row: Int
        let col: Int
        let style: String
        let color: SIMD4<Float>
    }

    private enum LigatureCacheEntry {
        case miss
        case hit(LigatureInfo)
    }

    // MARK: - Shared Caches (compiled once, reused across all renderer instances)

    private static var cachedLibrary: MTLLibrary?
    private static var cachedPipeline: MTLRenderPipelineState?
    private static var cachedBgPipeline: MTLRenderPipelineState?

    // Note: shared atlas was removed — the CGContext sharing caused thread-safety
    // issues and bitmap corruption. Per-renderer atlases cost ~5ms each for ASCII
    // pre-rasterization, which is acceptable.

    // MARK: - Metal Resources

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState!
    private var backgroundPipelineState: MTLRenderPipelineState!

    // Buffers
    private var instanceBuffer: MTLBuffer!
    private var uniformBuffer: MTLBuffer!
    private var vertexBuffer: MTLBuffer!
    private var instanceCapacity = 50000

    // MARK: - Glyph Atlas (Dynamic)

    private var glyphAtlas: MTLTexture!
    private var atlasContext: CGContext!
    private var atlasWidth = 2048
    private var atlasHeight = 2048
    private var glyphCache: [GlyphKey: GlyphInfo] = [:]
    /// Cache for multi-character ligature glyphs. nil value = font doesn't form a ligature.
    private var ligatureCache: [LigatureKey: LigatureCacheEntry] = [:]
    private var ligatureCacheInsertionOrder: [LigatureKey] = []
    private static let maxLigatureCacheEntries = 4096
    /// Whether ligature rendering is enabled (set from FeatureSettings)
    var ligaturesEnabled = false

    /// Packing cursor for the next glyph slot
    private var packX: CGFloat = 0
    private var packY: CGFloat = 0
    private var packRowHeight: CGFloat = 0

    /// Whether the atlas texture needs re-upload after new glyphs were rasterized
    private var atlasDirty = false
    /// Incremented whenever atlas coordinates are invalidated.
    private var atlasGeneration: UInt64 = 0

    /// Cache miss count for profiling
    private(set) var glyphCacheMisses = 0
    private(set) var glyphLookupCount = 0

    /// Diagnostic frame counter for throttled logging
    private var diagFrameCounter = 0
    private var lastCursorRowDiagnosticKey: String?

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
    var linkUnderlineColor: SIMD4<Float> = SIMD4(0, 0.48, 1, 1)
    var backgroundClearColor: MTLClearColor = MTLClearColorMake(0.1, 0.1, 0.1, 1.0)

    // MARK: - Blink State

    /// Current cursor blink phase (true = visible)
    var cursorBlinkPhase = true
    /// Whether cursor blink is enabled
    var cursorBlinkEnabled = true
    /// Current text blink phase (true = visible) — for cells with blink flag (bit 4)
    var textBlinkPhase = true
    /// Whether any cell in the current frame has the blink flag
    var hasBlinkingCells = false
    private var rowHasBlinkingCells: [Bool] = []
    private var blinkingRowCount = 0
    private var lastCursorRenderState: CursorRenderState?

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
        var linkUnderlineColor: SIMD4<Float>
    }

    // MARK: - Initialization

    init?(device: MTLDevice? = nil) {
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
        let instanceSize = MemoryLayout<CellInstance>.stride * instanceCapacity
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
    func setFont(nsFont: NSFont, scaleFactor: CGFloat = 1.0) {
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

        Log.trace("MetalRenderer: Font configured — \(CTFontCopyFullName(regularFont)), scaledSize=\(scaledSize), cellSize=\(cellSize), ascent=\(ascent), descent=\(descent)")

        // Guard against zero cell size (would make nothing visible)
        guard cellSize.width > 0, cellSize.height > 0 else {
            Log.error("MetalRenderer: Zero cell size from font \(CTFontCopyFullName(regularFont))")
            return
        }

        // Each renderer gets its own atlas — the ASCII pre-rasterization takes
        // ~5ms which is acceptable. Sharing the CGContext across renderers caused
        // thread-safety issues (concurrent draws) and bitmap corruption (stale data
        // from the originating renderer leaking into clones).
        resetAtlas()
        prerasterizeASCII()
        uploadAtlasTexture()
        Log.trace("MetalRenderer: Atlas populated with \(glyphCache.count) glyphs")
    }

    /// Clears glyph atlas and cache, resetting the packing cursor.
    private func resetAtlas() {
        atlasGeneration &+= 1
        glyphCache.removeAll()
        ligatureCache.removeAll()
        ligatureCacheInsertionOrder.removeAll(keepingCapacity: false)
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
                let byte = UInt8(cp)
                let data = Data([byte])
                _ = rasterizeGlyph(cluster: data, isWideHint: false, bold: style.bold, italic: style.italic)
            }
        }
    }

    // MARK: - Dynamic Glyph Rasterization

    @discardableResult
    func rasterizeGlyphForTesting(
        _ string: String,
        isWideHint: Bool = false,
        bold: Bool = false,
        italic: Bool = false
    ) -> GlyphInfo? {
        rasterizeGlyph(cluster: Data(string.utf8), isWideHint: isWideHint, bold: bold, italic: italic)
    }

    /// Rasterizes a single grapheme cluster into the atlas. Returns the GlyphInfo, or nil
    /// if the atlas is full or the cluster is empty.
    ///
    /// `isWideHint` comes from Rust's `WIDE_CHAR` flag (explicit width from the snapshot)
    /// and is preferred over the legacy advance-based heuristic. The advance check is
    /// kept as a fallback for clusters that arrive without a wide hint (e.g. ligatures).
    @discardableResult
    private func rasterizeGlyph(cluster: Data, isWideHint: Bool, bold: Bool, italic: Bool) -> GlyphInfo? {
        guard !cluster.isEmpty else { return nil }
        let key = GlyphKey(cluster: cluster, bold: bold, italic: italic)
        if let existing = glyphCache[key] { return existing }

        guard let context = atlasContext else { return nil }

        let font: CTFont
        switch (bold, italic) {
        case (true, true): font = boldItalicFont
        case (true, false): font = boldFont
        case (false, true): font = italicFont
        case (false, false): font = regularFont
        }

        let charStr = String(decoding: cluster, as: UTF8.self)
        guard !charStr.isEmpty else { return nil }
        let drawFont = CTFontCreateForString(font, charStr as CFString, CFRangeMake(0, charStr.utf16.count))
        let attrString = NSAttributedString(
            string: charStr,
            attributes: [.font: drawFont]
        )
        let line = CTLineCreateWithAttributedString(attrString)
        let runs = Self.runs(from: line)
        guard !runs.isEmpty else { return nil }

        let colorGlyphCandidate = Self.prefersEmbeddedColorGlyph(for: charStr)
            && Self.lineHasColorGlyphTableCandidate(runs)

        // Determine width: Rust's explicit hint takes precedence; fall back to
        // advance-based detection only when no hint was provided (single-byte
        // clusters in prerasterizeASCII).
        let isWide: Bool
        if isWideHint {
            isWide = true
        } else {
            let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            isWide = lineWidth > cellSize.width * 1.3
        }

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
            if packY + slotHeight > CGFloat(atlasHeight) {
                Log.error("MetalRenderer: Atlas still full after reset, cannot rasterize cluster \(charStr.debugDescription)")
                return nil
            }
        }

        packRowHeight = max(packRowHeight, slotHeight)

        // Draw the cluster into the atlas slot. We always set a white fill so
        // monochrome glyphs become alpha masks; color emoji fonts ignore the fill
        // and write embedded RGBA pixels. After drawing, sample the slot to decide
        // whether the shader should treat it as color data.
        context.saveGState()
        if colorGlyphCandidate {
            context.setShouldSmoothFonts(false)
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        let baselineY = CGFloat(atlasHeight) - packY - slotHeight + fontDescent
        context.textPosition = CGPoint(x: packX, y: baselineY)
        CTLineDraw(line, context)
        let boundingRect = CTLineGetImageBounds(line, context)
        let isColor = colorGlyphCandidate && Self.slotContainsColorPixels(
            context: context,
            x: Int(packX),
            y: Int(packY),
            width: Int(ceil(slotWidth)),
            height: Int(ceil(slotHeight))
        )
        context.restoreGState()

        // Diagnostic: check if box-drawing glyph produced visible pixels (trace-only)
        let firstScalar = charStr.unicodeScalars.first.map { $0.value } ?? 0
        let isBoxDraw = (0x2500 ... 0x257F).contains(firstScalar)
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
                    "[DIAG-SWIFT] rasterizeGlyph U+\(String(firstScalar, radix: 16, uppercase: true)) pixelCheck: \(nonZeroAlpha)/\(totalPixels) non-zero alpha, slot=(\(slotColStart),\(slotRowStart))-(\(slotColEnd),\(slotRowEnd)), baseline=\(baselineY), packY=\(packY)"
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
            isWide: isWide,
            isColor: isColor
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

    /// Looks up a glyph for a UTF-8 grapheme cluster, rasterizing on-demand. Returns
    /// the space glyph as a last-resort fallback.
    ///
    /// `isWideHint` should reflect the cell's `width == 2` from the Rust snapshot.
    private func lookupGlyph(cluster: Data, isWideHint: Bool, bold: Bool, italic: Bool) -> GlyphInfo? {
        glyphLookupCount += 1
        let key = GlyphKey(cluster: cluster, bold: bold, italic: italic)
        if let info = glyphCache[key] { return info }

        glyphCacheMisses += 1
        if let info = rasterizeGlyph(cluster: cluster, isWideHint: isWideHint, bold: bold, italic: italic) {
            return info
        }

        // Fallback: try regular style
        let fallbackKey = GlyphKey(cluster: cluster, bold: false, italic: false)
        if let info = glyphCache[fallbackKey] { return info }
        if let info = rasterizeGlyph(cluster: cluster, isWideHint: isWideHint, bold: false, italic: false) {
            return info
        }

        // Ultimate fallback: space
        return glyphCache[GlyphKey(cluster: Data([0x20]), bold: false, italic: false)]
    }

    // MARK: - Ligature Rendering

    // MARK: - Color Glyph Detection

    private static let colorGlyphTableTags: [CTFontTableTag] = [
        tableTag("sbix"),
        tableTag("COLR"),
        tableTag("CBDT"),
        tableTag("CBLC"),
        tableTag("SVG ")
    ]

    static func hasColorGlyphTables(font: CTFont) -> Bool {
        colorGlyphTableTags.contains { tag in
            CTFontCopyTable(font, tag, []) != nil
        }
    }

    private static func runs(from line: CTLine) -> [CTRun] {
        let rawRuns = CTLineGetGlyphRuns(line)
        let runCount = CFArrayGetCount(rawRuns)
        guard runCount > 0 else { return [] }

        var runs: [CTRun] = []
        runs.reserveCapacity(runCount)
        for index in 0 ..< runCount {
            let rawRun = CFArrayGetValueAtIndex(rawRuns, index)
            let run = unsafeBitCast(rawRun, to: CTRun.self)
            guard CFGetTypeID(run) == CTRunGetTypeID() else { continue }
            runs.append(run)
        }
        return runs
    }

    private static func lineHasColorGlyphTableCandidate(_ runs: [CTRun]) -> Bool {
        for run in runs {
            let attrs = CTRunGetAttributes(run)
            let key = Unmanaged.passUnretained(kCTFontAttributeName).toOpaque()
            guard let rawFont = CFDictionaryGetValue(attrs, key) else { continue }
            let font = unsafeBitCast(rawFont, to: CTFont.self)
            guard CFGetTypeID(font) == CTFontGetTypeID() else { continue }
            guard hasColorGlyphTables(font: font) else { continue }

            let glyphCount = CTRunGetGlyphCount(run)
            guard glyphCount > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: glyphCount)
            CTRunGetGlyphs(run, CFRangeMake(0, 0), &glyphs)
            if glyphs.contains(where: { $0 != 0 }) {
                return true
            }
        }
        return false
    }

    private static func prefersEmbeddedColorGlyph(for string: String) -> Bool {
        let scalars = string.unicodeScalars.map(\.value)

        // Respect explicit presentation selectors first. Terminal TUIs often use
        // emoji-capable symbols as text and color them with ANSI; only the emoji
        // presentation should bypass ANSI foreground tinting.
        if scalars.contains(0xFE0E) { return false }
        if scalars.contains(0xFE0F) { return true }

        return scalars.contains(where: isDefaultEmojiPresentationScalar)
    }

    private static func isDefaultEmojiPresentationScalar(_ scalar: UInt32) -> Bool {
        if (0x1F000 ... 0x1FAFF).contains(scalar) {
            return true
        }

        switch scalar {
        case 0x231A ... 0x231B,
             0x23E9 ... 0x23EC,
             0x23F0,
             0x23F3,
             0x25FD ... 0x25FE,
             0x2614 ... 0x2615,
             0x2648 ... 0x2653,
             0x267F,
             0x2693,
             0x26A1,
             0x26AA ... 0x26AB,
             0x26BD ... 0x26BE,
             0x26C4 ... 0x26C5,
             0x26CE,
             0x26D4,
             0x26EA,
             0x26F2 ... 0x26F3,
             0x26F5,
             0x26FA,
             0x26FD,
             0x2705,
             0x270A ... 0x270B,
             0x2728,
             0x274C,
             0x274E,
             0x2753 ... 0x2755,
             0x2757,
             0x2795 ... 0x2797,
             0x27B0,
             0x27BF:
            return true
        default:
            return false
        }
    }

    static func slotContainsColorPixels(
        context: CGContext,
        x: Int,
        y: Int,
        width: Int,
        height: Int
    ) -> Bool {
        guard let data = context.data else { return false }
        return slotContainsColorPixels(
            data: data,
            bytesPerRow: context.bytesPerRow,
            atlasWidth: context.width,
            atlasHeight: context.height,
            x: x,
            y: y,
            width: width,
            height: height
        )
    }

    static func slotContainsColorPixels(
        data: UnsafeRawPointer,
        bytesPerRow: Int,
        atlasWidth: Int,
        atlasHeight: Int,
        x: Int,
        y: Int,
        width: Int,
        height: Int
    ) -> Bool {
        guard bytesPerRow > 0, atlasWidth > 0, atlasHeight > 0, width > 0, height > 0 else {
            return false
        }

        let xStart = max(0, x)
        let yStart = max(0, y)
        let xEnd = min(x + width, min(atlasWidth, bytesPerRow / 4))
        let yEnd = min(y + height, atlasHeight)
        guard xStart < xEnd, yStart < yEnd else { return false }

        let ptr = data.bindMemory(to: UInt8.self, capacity: atlasHeight * bytesPerRow)
        for row in yStart ..< yEnd {
            for col in xStart ..< xEnd {
                let offset = row * bytesPerRow + col * 4
                let red = Int(ptr[offset])
                let green = Int(ptr[offset + 1])
                let blue = Int(ptr[offset + 2])
                let alpha = Int(ptr[offset + 3])
                guard alpha > 8 else { continue }
                if abs(red - green) > 3 || abs(red - blue) > 3 || abs(green - blue) > 3 {
                    return true
                }
            }
        }
        return false
    }

    private static func tableTag(_ raw: String) -> CTFontTableTag {
        raw.utf8.reduce(CTFontTableTag(0)) { partial, byte in
            (partial << 8) | CTFontTableTag(byte)
        }
    }

    /// Try to form a ligature from consecutive cells. Returns nil if the font doesn't
    /// produce a ligature for this sequence (glyph count == char count = no substitution).
    func lookupLigature(sequence: String, bold: Bool, italic: Bool) -> LigatureInfo? {
        let key = LigatureKey(sequence: sequence, bold: bold, italic: italic)
        if let cached = ligatureCache[key] {
            switch cached {
            case .miss:
                return nil
            case let .hit(info):
                return info
            }
        }

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
            cacheLigature(.miss, for: key)
            return nil
        }

        let glyphCount = CTRunGetGlyphCount(run)
        let charCount = sequence.count

        // If glyph count equals char count, no ligature was formed
        if glyphCount >= charCount {
            cacheLigature(.miss, for: key)
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
            cacheLigature(.miss, for: key)
            return nil
        }
        packRowHeight = max(packRowHeight, slotHeight)

        // Draw the ligature sequence into the atlas bitmap
        guard let context = atlasContext else {
            cacheLigature(.miss, for: key)
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
        cacheLigature(.hit(info), for: key)
        packX += slotWidth + padding
        atlasDirty = true
        return info
    }

    private func cacheLigature(_ entry: LigatureCacheEntry, for key: LigatureKey) {
        if ligatureCache[key] == nil {
            ligatureCacheInsertionOrder.append(key)
        }
        ligatureCache[key] = entry
        trimLigatureCacheIfNeeded()
    }

    private func trimLigatureCacheIfNeeded() {
        let evictionCount = RenderMemoryPressurePolicy.ligatureEvictionCount(
            currentCount: ligatureCache.count,
            limit: Self.maxLigatureCacheEntries
        )
        guard evictionCount > 0 else { return }

        let keysToRemove = Array(ligatureCacheInsertionOrder.prefix(evictionCount))
        for key in keysToRemove {
            ligatureCache.removeValue(forKey: key)
        }
        ligatureCacheInsertionOrder.removeFirst(keysToRemove.count)
        Log.warn(
            "MetalRenderer: trimmed ligature cache by \(keysToRemove.count) entries; remaining=\(ligatureCache.count)"
        )
    }

    /// Maximum lookahead for ligature detection (3-char sequences like ===, !==)
    private static let maxLigatureLength = 3

    /// Try to form a ligature from consecutive cells starting at index.
    /// Returns nil if no ligature is formed or if the cells cross a row boundary.
    ///
    /// Ligatures only form from printable ASCII single-byte clusters with the same
    /// style. Multi-codepoint clusters (emoji, RI flags, combining marks) cannot
    /// participate in a ligature run.
    private func tryLigature(
        cells: UnsafeBufferPointer<TerminalCell>,
        clusters: ContiguousArray<UInt8>,
        index: Int, count: Int, cols: Int,
        bold: Bool, italic: Bool
    ) -> LigatureInfo? {
        let col = index % cols
        let maxLen = min(Self.maxLigatureLength, cols - col, count - index)
        guard maxLen >= 2 else { return nil }

        for len in stride(from: maxLen, through: 2, by: -1) {
            var sequence = ""
            var valid = true
            for j in 0 ..< len {
                let c = cells[index + j]
                guard c.clusterLen == 1, c.continuation == 0 else { valid = false
                    break
                }
                let byte = clusters[Int(c.clusterStart)]
                guard byte >= 0x21, byte < 0x7F else { valid = false
                    break
                }
                let cBold = (c.flags & 1) != 0
                let cItalic = (c.flags & 2) != 0
                if cBold != bold || cItalic != italic { valid = false
                    break
                }
                sequence.append(Character(Unicode.Scalar(byte)))
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
    ///
    /// `buffer` provides both the cell instances and the parallel `clusters` byte
    /// buffer that cells index into for grapheme cluster bytes. The renderer must
    /// receive them together — cluster offsets are only meaningful relative to a
    /// specific frame's buffer.
    func render(
        buffer: TripleBufferedTerminal.TerminalBuffer,
        rows: Int,
        cols: Int,
        dirtyRows: IndexSet,
        fullRefresh: Bool,
        to drawable: CAMetalDrawable,
        viewportSize: CGSize,
        onCompleted: (() -> Void)? = nil
    ) -> Bool {
        let renderStartedAt = CFAbsoluteTimeGetCurrent()
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return false }

        let cells = UnsafeBufferPointer(buffer.cells)
        let clusters = buffer.clusters
        let requestedCellCount = min(cells.count, max(0, rows * cols))
        let grewInstanceBuffer = growInstanceBufferIfNeeded(for: requestedCellCount)
        let cellCount = min(requestedCellCount, instanceCapacity)

        // Update instance buffer (may trigger on-demand glyph rasterization).
        // If glyph rasterization resets the atlas mid-update, previously written
        // UVs point into the old atlas. Retry as a full refresh until all UVs
        // are produced against one atlas generation.
        let instanceStartedAt = CFAbsoluteTimeGetCurrent()
        var updateDirtyRows = dirtyRows
        var updateFullRefresh = fullRefresh || grewInstanceBuffer
        let maxAtlasRetryCount = 3
        for attempt in 0 ..< maxAtlasRetryCount {
            let generationBeforeUpdate = atlasGeneration
            updateInstanceBuffer(
                cells: cells,
                clusters: clusters,
                count: cellCount,
                rows: rows,
                cols: cols,
                dirtyRows: updateDirtyRows,
                fullRefresh: updateFullRefresh
            )
            guard atlasGeneration != generationBeforeUpdate else { break }

            updateDirtyRows = IndexSet(integersIn: 0 ..< rows)
            updateFullRefresh = true
            if attempt == maxAtlasRetryCount - 1 {
                Log.error("MetalRenderer: Atlas reset repeatedly during one frame; presenting best-effort full refresh")
            } else {
                Log.warn("MetalRenderer: Atlas reset during instance update; retrying full refresh")
            }
        }
        let instanceDurationMs = (CFAbsoluteTimeGetCurrent() - instanceStartedAt) * 1000.0
        FeatureProfiler.shared.record(feature: .metalInstanceBuffer, durationMs: instanceDurationMs)

        // Upload atlas if new glyphs were rasterized
        if atlasDirty { uploadAtlasTexture() }

        updateUniforms(viewportSize: viewportSize)

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = drawable.texture
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].storeAction = .store
        passDescriptor.colorAttachments[0].clearColor = backgroundClearColor

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else { return false }

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

        if let onCompleted {
            commandBuffer.addCompletedHandler { _ in
                DispatchQueue.main.async {
                    onCompleted()
                }
            }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        let renderDurationMs = (CFAbsoluteTimeGetCurrent() - renderStartedAt) * 1000.0
        FeatureProfiler.shared.record(feature: .metalDrawStage, durationMs: renderDurationMs)
        return true
    }

    private func updateInstanceBuffer(
        cells: UnsafeBufferPointer<TerminalCell>,
        clusters: ContiguousArray<UInt8>,
        count: Int,
        rows: Int,
        cols: Int,
        dirtyRows: IndexSet,
        fullRefresh: Bool
    ) {
        let startingGlyphLookups = glyphLookupCount
        let startingGlyphMisses = glyphCacheMisses
        let instances = instanceBuffer.contents().bindMemory(to: CellInstance.self, capacity: count)
        // Cell size in points (not scaled — scaling happens in the atlas and texture UVs)
        let cw = Float(cellSize.width / scaleFactor)
        let ch = Float(cellSize.height / scaleFactor)

        let renderableRows = cols > 0 ? min(rows, (count + cols - 1) / cols) : 0
        let hasRowMetadata = rowHasBlinkingCells.count == renderableRows
        if !hasRowMetadata {
            rowHasBlinkingCells = Array(repeating: false, count: renderableRows)
            blinkingRowCount = 0
        }

        let currentCursorState = currentCursorRenderState(count: count, cols: cols)
        let rowsToUpdate = MetalInstanceUpdatePlanner.rowsToRefresh(
            totalRows: renderableRows,
            dirtyRows: dirtyRows,
            fullRefresh: fullRefresh || !hasRowMetadata,
            previousCursorRow: lastCursorRenderState?.row,
            currentCursorRow: currentCursorState?.row,
            cursorNeedsRefresh: lastCursorRenderState != currentCursorState
        )

        var updatedCellCount = 0
        var boxDrawCount = 0
        let traceBoxDraw = Log.isTraceEnabled && diagFrameCounter.isMultiple(of: 600)

        for row in rowsToUpdate {
            let rowStart = row * cols
            let rowCellCount = min(cols, count - rowStart)
            guard rowCellCount > 0 else { continue }

            var rowHasBlinking = false
            var ligatureSkip = 0
            var ligatureRect = CGRect.zero
            var ligatureSpan = 0
            var ligatureSlice = 0

            for col in 0 ..< rowCellCount {
                let index = rowStart + col
                let cell = cells[index]
                let isBold = (cell.flags & 1) != 0
                let isItalic = (cell.flags & 2) != 0

                if (cell.flags & 16) != 0 {
                    rowHasBlinking = true
                }

                var texCoord: SIMD4<Float> = SIMD4(0, 0, 0, 0)
                var instanceFlags = cell.flags

                // Continuation cells (right half of a wide grapheme) emit the
                // RIGHT half of the wide glyph's atlas rect — the wide glyph at
                // (row, col-1) emits the left half. Together they tile a 2-cell
                // glyph using 1-cell quads, with no shader changes needed.
                if cell.continuation != 0 {
                    if col > 0 {
                        let prev = cells[index - 1]
                        if prev.width == 2, prev.clusterLen > 0 {
                            let prevBold = (prev.flags & 1) != 0
                            let prevItalic = (prev.flags & 2) != 0
                            let cluster = Data(clusters[Int(prev.clusterStart) ..< Int(prev.clusterStart) + Int(prev.clusterLen)])
                            if let info = lookupGlyph(cluster: cluster, isWideHint: true, bold: prevBold, italic: prevItalic) {
                                let half = Float(info.textureRect.width) * 0.5
                                texCoord = SIMD4(
                                    Float(info.textureRect.origin.x) + half,
                                    Float(info.textureRect.origin.y),
                                    half,
                                    Float(info.textureRect.height)
                                )
                                if info.isColor { instanceFlags |= TerminalCell.colorGlyphFlag }
                            }
                        }
                    }
                } else if cell.clusterLen > 0 {
                    // Ligatures: ASCII-only, single-byte clusters with same style.
                    if ligaturesEnabled,
                       cell.clusterLen == 1,
                       ligatureSkip <= 0,
                       clusters[Int(cell.clusterStart)] >= 0x21,
                       clusters[Int(cell.clusterStart)] < 0x7F {
                        if let lig = tryLigature(
                            cells: cells,
                            clusters: clusters,
                            index: index,
                            count: count,
                            cols: cols,
                            bold: isBold,
                            italic: isItalic
                        ) {
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
                            ligatureSlice = 1
                        }
                    }

                    if ligatureSkip > 0, texCoord == SIMD4(0, 0, 0, 0) {
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
                        let cluster = Data(clusters[Int(cell.clusterStart) ..< Int(cell.clusterStart) + Int(cell.clusterLen)])

                        // Diagnostic: log box-drawing glyph resolution
                        if cell.clusterLen == 3 {
                            let b0 = cluster[0], b1 = cluster[1]
                            if b0 == 0xE2, b1 == 0x94 || b1 == 0x95 { // U+2500..U+257F is encoded 0xE2 94/95 ..
                                boxDrawCount += 1
                                if traceBoxDraw, boxDrawCount <= 3 {
                                    let fg = cell.foregroundColor
                                    let bg = cell.backgroundColor
                                    let s = String(decoding: cluster, as: UTF8.self)
                                    Log.trace(
                                        "[DIAG-SWIFT] box-draw: '\(s)' at (\(row),\(col)) fg=(\(String(format: "%.2f", fg.x)),\(String(format: "%.2f", fg.y)),\(String(format: "%.2f", fg.z))) bg=(\(String(format: "%.2f", bg.x)),\(String(format: "%.2f", bg.y)),\(String(format: "%.2f", bg.z)))"
                                    )
                                }
                            }
                        }

                        if let info = lookupGlyph(cluster: cluster, isWideHint: cell.width == 2, bold: isBold, italic: isItalic) {
                            // Wide glyphs are tiled as left+right halves across
                            // this cell + the continuation cell to its right.
                            // Emit only the LEFT half here.
                            if cell.width == 2 {
                                let half = Float(info.textureRect.width) * 0.5
                                texCoord = SIMD4(
                                    Float(info.textureRect.origin.x),
                                    Float(info.textureRect.origin.y),
                                    half,
                                    Float(info.textureRect.height)
                                )
                            } else {
                                texCoord = SIMD4(
                                    Float(info.textureRect.origin.x),
                                    Float(info.textureRect.origin.y),
                                    Float(info.textureRect.width),
                                    Float(info.textureRect.height)
                                )
                            }
                            if info.isColor { instanceFlags |= TerminalCell.colorGlyphFlag }
                        }
                    }
                }

                instances[index] = CellInstance(
                    position: SIMD2(Float(col) * cw, Float(row) * ch),
                    texCoord: texCoord,
                    foreground: cell.foregroundColor,
                    background: cell.backgroundColor,
                    cursorColor: SIMD4(0, 0, 0, 0),
                    flags: instanceFlags
                )
            }

            if rowHasBlinkingCells[row] != rowHasBlinking {
                blinkingRowCount += rowHasBlinking ? 1 : -1
                rowHasBlinkingCells[row] = rowHasBlinking
            }

            updatedCellCount += rowCellCount
        }

        hasBlinkingCells = blinkingRowCount > 0

        if boxDrawCount > 0 {
            diagFrameCounter += 1
            if Log.isTraceEnabled, diagFrameCounter % 300 == 1 {
                Log.trace(
                    "[DIAG-SWIFT] updateInstanceBuffer: \(boxDrawCount) box-drawing cells in refreshed rows (\(updatedCellCount) updated cells, \(count) total cells, \(cols) cols)"
                )
            }
        }

        applyCursor(to: instances, count: count, cols: cols, cursorState: currentCursorState)
        lastCursorRenderState = currentCursorState
        if let cursorState = currentCursorState {
            logCursorRowMappingIfNeeded(
                cells: cells,
                clusters: clusters,
                instances: instances,
                count: count,
                cols: cols,
                row: cursorState.row,
                cursorCol: cursorState.col
            )
        }

        let frameGlyphLookups = glyphLookupCount - startingGlyphLookups
        let frameGlyphMisses = glyphCacheMisses - startingGlyphMisses
        RenderPipelineProfiler.shared.recordInstanceBuffer(
            cells: updatedCellCount,
            bufferBytes: updatedCellCount * MemoryLayout<CellInstance>.stride,
            saturated: count == instanceCapacity && cells.count > count,
            glyphLookups: frameGlyphLookups,
            glyphMisses: frameGlyphMisses,
            glyphCacheSize: glyphCache.count,
            ligatureCacheSize: ligatureCache.count
        )
    }

    @discardableResult
    private func growInstanceBufferIfNeeded(for requiredCells: Int) -> Bool {
        guard requiredCells > instanceCapacity else { return false }

        let newCapacity = max(requiredCells, instanceCapacity * 2)
        let newSize = MemoryLayout<CellInstance>.stride * newCapacity
        guard let newBuffer = device.makeBuffer(length: newSize, options: .storageModeShared) else {
            Log.error(
                "MetalRenderer: Failed to grow instance buffer to \(newCapacity) cells; rendering capped at \(instanceCapacity)"
            )
            return false
        }

        instanceBuffer = newBuffer
        instanceCapacity = newCapacity
        rowHasBlinkingCells.removeAll(keepingCapacity: false)
        blinkingRowCount = 0
        lastCursorRenderState = nil
        Log.info("MetalRenderer: Grew instance buffer to \(newCapacity) cells")
        return true
    }

    private func currentCursorRenderState(count: Int, cols: Int) -> CursorRenderState? {
        guard cols > 0 else { return nil }
        let showCursor = cursorVisible && (!cursorBlinkEnabled || cursorBlinkPhase)
        guard showCursor else { return nil }
        let cursorIndex = cursorRow * cols + cursorCol
        guard cursorIndex >= 0, cursorIndex < count else { return nil }
        return CursorRenderState(
            row: cursorRow,
            col: cursorCol,
            style: cursorStyle,
            color: cursorColor
        )
    }

    private func applyCursor(
        to instances: UnsafeMutablePointer<CellInstance>,
        count: Int,
        cols: Int,
        cursorState: CursorRenderState?
    ) {
        guard let cursorState, cols > 0 else { return }
        let cursorIndex = cursorState.row * cols + cursorState.col
        guard cursorIndex >= 0, cursorIndex < count else { return }

        var flags = instances[cursorIndex].flags | (1 << 5)
        switch cursorState.style {
        case "underline":
            flags |= (1 << 6)
        case "bar":
            flags |= (2 << 6)
        default:
            break
        }
        instances[cursorIndex].flags = flags
        instances[cursorIndex].cursorColor = cursorState.color
    }

    private func logCursorRowMappingIfNeeded(
        cells: UnsafeBufferPointer<TerminalCell>,
        clusters: ContiguousArray<UInt8>,
        instances: UnsafeMutablePointer<CellInstance>,
        count: Int,
        cols: Int,
        row: Int,
        cursorCol: Int
    ) {
        guard EnvVars.isEnabled(EnvVars.renderRowDiagnostics) else { return }
        guard cols > 0, row >= 0 else { return }
        let rowStart = row * cols
        guard rowStart < count else { return }

        let rowEndExclusive = min(rowStart + cols, count)
        let rowSlice = UnsafeBufferPointer(
            start: cells.baseAddress?.advanced(by: rowStart),
            count: rowEndExclusive - rowStart
        )
        guard !rowSlice.isEmpty else { return }

        let window = Self.diagnosticWindow(for: rowSlice, cursorCol: cursorCol)
        guard !window.isEmpty else { return }

        var hasher = Hasher()
        hasher.combine(row)
        hasher.combine(cursorCol)
        hasher.combine(window.lowerBound)
        hasher.combine(window.upperBound)
        for col in window {
            let cell = rowSlice[col]
            let instance = instances[rowStart + col]
            hasher.combine(cell.clusterStart)
            hasher.combine(cell.clusterLen)
            hasher.combine(cell.flags)
            hasher.combine(instance.texCoord.x.bitPattern)
            hasher.combine(instance.texCoord.y.bitPattern)
            hasher.combine(instance.texCoord.z.bitPattern)
            hasher.combine(instance.texCoord.w.bitPattern)
        }
        let diagnosticKey = "cursor-row:\(hasher.finalize())"
        guard diagnosticKey != lastCursorRowDiagnosticKey else { return }
        lastCursorRowDiagnosticKey = diagnosticKey

        let textPreview = window.map { Self.diagnosticPreview(for: rowSlice[$0], clusters: clusters) }.joined()
        let mappingSummary = window.map { col -> String in
            let cell = rowSlice[col]
            let instance = instances[rowStart + col]
            let tex = instance.texCoord
            let mapping = tex.z > 0 && tex.w > 0
                ? String(format: "uv=(%.3f,%.3f,%.3f,%.3f)", tex.x, tex.y, tex.z, tex.w)
                : "uv=missing"
            return "\(col):\(Self.diagnosticScalarLabel(for: cell, clusters: clusters)) \(mapping) f=\(String(format: "%02X", cell.flags))"
        }.joined(separator: " ")

        let hasMissingGlyph = window.contains { col in
            let cell = rowSlice[col]
            let tex = instances[rowStart + col].texCoord
            return cell.clusterLen > 0 && cell.continuation == 0 && (tex.z == 0 || tex.w == 0)
        }

        let message =
            "MetalRenderer: input-row glyph map viewportRow=\(row) cursorCol=\(cursorCol) cols=\(window.lowerBound)-\(window.upperBound) text=\(textPreview.debugDescription) cells=[\(mappingSummary)]"
        if hasMissingGlyph {
            Log.warn(message)
        } else {
            Log.debug(message)
        }
    }

    private static func diagnosticWindow(
        for rowCells: UnsafeBufferPointer<TerminalCell>,
        cursorCol: Int,
        maxWidth: Int = 48
    ) -> ClosedRange<Int> {
        guard !rowCells.isEmpty else { return 0 ... 0 }
        let cursor = min(max(cursorCol, 0), rowCells.count - 1)
        let interestingCols = rowCells.indices.filter { col in
            let cell = rowCells[col]
            return col == cursor || cell.clusterLen > 0 || cell.flags != 0
        }

        let rawStart = interestingCols.min() ?? cursor
        let rawEnd = interestingCols.max() ?? cursor
        var start = max(0, rawStart - 2)
        var end = min(rowCells.count - 1, rawEnd + 2)

        if end - start + 1 > maxWidth {
            start = max(0, cursor - (maxWidth / 2))
            end = min(rowCells.count - 1, start + maxWidth - 1)
            start = max(0, end - maxWidth + 1)
        }

        return start ... end
    }

    private static func diagnosticPreview(for cell: TerminalCell, clusters: ContiguousArray<UInt8>) -> String {
        if cell.clusterLen == 0 { return " " }
        if cell.continuation != 0 { return "" }
        let start = Int(cell.clusterStart)
        let end = start + Int(cell.clusterLen)
        guard end <= clusters.count else { return "�" }
        let bytes = Array(clusters[start ..< end])
        // Control characters → middle dot
        if bytes.count == 1, bytes[0] < 0x20 || bytes[0] == 0x7F { return "·" }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func diagnosticScalarLabel(for cell: TerminalCell, clusters: ContiguousArray<UInt8>) -> String {
        if cell.clusterLen == 0 { return "SP" }
        if cell.continuation != 0 { return "CONT" }
        let start = Int(cell.clusterStart)
        let end = start + Int(cell.clusterLen)
        guard end <= clusters.count else { return "INVALID" }
        let bytes = Array(clusters[start ..< end])
        if bytes.count == 1 {
            let b = bytes[0]
            if b == 0x20 { return "SP" }
            if b < 0x20 || b == 0x7F { return "CTRL" }
            return String(format: "U+%04X", b)
        }
        let str = String(decoding: bytes, as: UTF8.self)
        if let first = str.unicodeScalars.first, str.unicodeScalars.count == 1 {
            return String(format: "U+%04X", first.value)
        }
        // Multi-codepoint cluster — show as quoted string
        return str.debugDescription
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
            underlineY: underlinePosition,
            linkUnderlineColor: linkUnderlineColor
        )
    }

    // MARK: - Purgeable / Memory Volatility

    /// Marks the glyph atlas and instance buffer as volatile / non-volatile.
    ///
    /// - `.volatile`: the OS may reclaim the GPU memory under pressure. If no
    ///   pressure occurs, data is preserved — no cost on promotion back.
    /// - `.nonVolatile`: reserves the memory again. Returns the PRIOR state
    ///   (i.e. the state at the time of the call). If the prior state is
    ///   `.empty`, the OS reclaimed the data while it was volatile and the
    ///   caller must rebuild (call `clearGlyphCache()` and let the next draw
    ///   re-rasterize).
    func setAtlasPurgeableState(_ state: MTLPurgeableState) -> MTLPurgeableState {
        let atlasPrior = glyphAtlas?.setPurgeableState(state) ?? .keepCurrent
        _ = instanceBuffer?.setPurgeableState(state)
        _ = uniformBuffer?.setPurgeableState(state)
        _ = vertexBuffer?.setPurgeableState(state)
        return atlasPrior
    }

    /// Drops the CPU-side glyph and ligature caches. Next draw will re-rasterize
    /// all used glyphs into the atlas. Used after the OS reclaims a volatile
    /// atlas texture so the CPU cache doesn't point at empty GPU slots.
    func clearGlyphCache() {
        resetAtlas()
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

/// Represents a single terminal cell for GPU rendering.
///
/// Cells reference UTF-8 grapheme cluster bytes stored in the owning
/// `TerminalBuffer.clusters` array (offset + length). `width` and `continuation`
/// come straight from the Rust snapshot — the renderer no longer probes glyph
/// advance to decide cell span.
struct TerminalCell {
    static let boldFlag: UInt32 = 1 << 0
    static let italicFlag: UInt32 = 1 << 1
    static let underlineFlag: UInt32 = 1 << 2
    static let strikethroughFlag: UInt32 = 1 << 3
    static let blinkFlag: UInt32 = 1 << 4
    static let cursorPresentFlag: UInt32 = 1 << 5
    static let linkUnderlineFlag: UInt32 = 1 << 11
    /// Set per-instance when the resolved glyph is a color bitmap (sbix/COLR/CBDT).
    /// Fragment shader samples `texColor.rgb` directly instead of tinting `fg`.
    static let colorGlyphFlag: UInt32 = 1 << 12

    /// Byte offset into the owning `TerminalBuffer.clusters` array.
    var clusterStart: UInt32
    var foregroundColor: SIMD4<Float>
    var backgroundColor: SIMD4<Float>
    /// Bold=1, italic=2, underline=4, strikethrough=8, blink=16
    /// Cursor bits (set by renderer): cursor_present=32, cursor_style in bits 6-7
    /// Color-glyph bit 12 is set when this cell's atlas slot is a color bitmap.
    var flags: UInt32
    /// UTF-8 byte length of the grapheme cluster. 0 = blank cell.
    var clusterLen: UInt16
    /// 1 = narrow, 2 = wide; 0 on continuation cells.
    var width: UInt8
    /// 1 = right half of a wide grapheme owned by the cell to the left.
    var continuation: UInt8

    init(
        clusterStart: UInt32 = 0,
        clusterLen: UInt16 = 0,
        foreground: SIMD4<Float> = SIMD4(1, 1, 1, 1),
        background: SIMD4<Float> = SIMD4(0, 0, 0, 1),
        flags: UInt32 = 0,
        width: UInt8 = 1,
        continuation: UInt8 = 0
    ) {
        self.clusterStart = clusterStart
        self.foregroundColor = foreground
        self.backgroundColor = background
        self.flags = flags
        self.clusterLen = clusterLen
        self.width = width
        self.continuation = continuation
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
        float4 cursorColor;
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
        float4 linkUnderlineColor;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 texCoord;
        float2 cellLocalPos;  // 0..1 within the cell (for decorations)
        float4 foreground;
        float4 background;
        float4 cursorColor;
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
        out.cursorColor = instance.cursorColor;
        out.flags = instance.flags;
        return out;
    }

    fragment float4 backgroundFragmentShader(VertexOut in [[stage_in]]) {
        // Cursor: block style fills the entire cell with cursor color
        bool hasCursor = (in.flags & (1u << 5)) != 0;
        uint cursorStyle = (in.flags >> 6) & 3u;
        if (hasCursor && cursorStyle == 0) {
            return in.cursorColor;
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
        out.cursorColor = instance.cursorColor;
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

        // Color glyph branch (bit 12): the atlas slot stores RGBA color data
        // (Apple Color Emoji, sbix/COLR/CBDT). Sample texture directly and let
        // the foreground alpha control overall opacity (e.g., for dim text).
        // Monochrome glyphs continue to tint texColor.a by foreground.rgb.
        bool isColorGlyph = (in.flags & (1u << 12)) != 0;
        float4 color = isColorGlyph
            ? float4(texColor.rgb, texColor.a * in.foreground.a)
            : float4(in.foreground.rgb, texColor.a * in.foreground.a);

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
                    return in.cursorColor;
                }
            } else if (cursorStyle == 2) {
                // Bar cursor: draw a thin line on the left
                if (in.cellLocalPos.x < 0.08) {
                    return in.cursorColor;
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

        // OSC 8 link underline, used only when the cell does not already carry
        // an explicit underline style from SGR.
        if ((in.flags & (1u << 11)) != 0) {
            float underlineY = uniforms.underlineY;
            if (in.cellLocalPos.y > underlineY && in.cellLocalPos.y < underlineY + thickness) {
                return uniforms.linkUnderlineColor;
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
