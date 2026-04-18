// MARK: - Metal-Based Terminal Renderer

// GPU-accelerated terminal rendering with compact 32-byte cells,
// single-pass compositing, ring-buffered instance data, and
// ASCII fast-path glyph lookup.

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

// MARK: - Cell Instance (Compact GPU Format)

/// Per-cell data uploaded to GPU. 32 bytes — position computed from instanceID.
struct CellInstance {
    var texCoord: SIMD4<Float> // Glyph UV rect (u, v, width, height) — 16 bytes
    var colors: SIMD2<UInt32> // Packed RGBA: .x = foreground, .y = background — 8 bytes
    var flags: UInt32 // Style/cursor/decoration bits — 4 bytes
    var _pad: UInt32 = 0 // Alignment to 32 bytes

    /// Pack an RGBA color from float components into a single UInt32.
    @inline(__always)
    static func packColor(_ r: Float, _ g: Float, _ b: Float, _ a: Float) -> UInt32 {
        let rb = UInt32(min(max(r, 0), 1) * 255)
        let gb = UInt32(min(max(g, 0), 1) * 255)
        let bb = UInt32(min(max(b, 0), 1) * 255)
        let ab = UInt32(min(max(a, 0), 1) * 255)
        return rb | (gb << 8) | (bb << 16) | (ab << 24)
    }

    /// Pack an RGBA color from u8 components.
    @inline(__always)
    static func packColor(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) -> UInt32 {
        UInt32(r) | (UInt32(g) << 8) | (UInt32(b) << 16) | (UInt32(a) << 24)
    }
}

// MARK: - Glyph Types

/// Glyph cache key: codepoint + style variant
struct GlyphKey: Hashable {
    let codePoint: UInt32
    let bold: Bool
    let italic: Bool
}

/// Glyph atlas entry
struct GlyphInfo {
    let textureRect: CGRect // UV coordinates in atlas
    let isWide: Bool // Double-width (CJK)
}

/// Ligature atlas entry
struct LigatureInfo {
    let textureRect: CGRect
    let cellSpan: Int
}

// MARK: - Renderer

final class MetalTerminalRenderer {

    // MARK: - Shared Pipeline Cache (keyed by device)

    private static var pipelineCache: [ObjectIdentifier: (MTLRenderPipelineState, MTLLibrary)] = [:]

    // MARK: - Metal Resources

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState!

    // Ring buffer: 3 instance buffers rotated per frame
    static let ringBufferCount = 3
    private(set) var instanceBuffers: [MTLBuffer] = []
    private(set) var ringIndex = 0
    private var uniformBuffer: MTLBuffer!
    private var vertexBuffer: MTLBuffer!

    /// Current capacity in cells. Grows dynamically when grid exceeds it.
    private var cellCapacity = 0

    // MARK: - Glyph Atlas

    private var glyphAtlas: MTLTexture!
    private var atlasContext: CGContext!
    private let atlasWidth = 2048
    private let atlasHeight = 2048

    /// Full glyph cache for Unicode characters beyond ASCII
    private var glyphCache: [GlyphKey: GlyphInfo] = [:]

    /// ASCII fast-path: flat array for codepoints 32-126, 4 style variants each.
    /// Index = (codePoint - 32) * 4 + styleIndex where styleIndex = bold*1 + italic*2
    private var asciiGlyphs: [GlyphInfo?] = []
    private static let asciiBase: UInt32 = 32
    private static let asciiCount: UInt32 = 95 // 32..126
    private static let styleVariants = 4

    /// Ligature cache
    private enum LigatureCacheEntry {
        case miss
        case hit(LigatureInfo)
    }

    private var ligatureCache: [LigatureKey: LigatureCacheEntry] = [:]
    private var ligatureCacheInsertionOrder: [LigatureKey] = []
    private static let maxLigatureCacheEntries = 4096
    var ligaturesEnabled = false

    struct LigatureKey: Hashable {
        let sequence: String
        let bold: Bool
        let italic: Bool
    }

    /// Atlas packing cursor
    private var packX: CGFloat = 0
    private var packY: CGFloat = 0
    private var packRowHeight: CGFloat = 0
    private var atlasDirty = false

    /// Profiling counters
    private(set) var glyphCacheMisses = 0
    private(set) var glyphLookupCount = 0
    var glyphCacheCount: Int {
        glyphCache.count
    }

    var ligatureCacheCount: Int {
        ligatureCache.count
    }

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
    private var underlinePosition: Float = 0.88

    // MARK: - Cursor State

    var cursorRow = 0
    var cursorCol = 0
    var cursorStyle = "block"
    var cursorVisible = true
    var cursorColor: SIMD4<Float> = SIMD4(1, 1, 1, 0.7)

    // MARK: - Blink State

    var cursorBlinkPhase = true
    var cursorBlinkEnabled = true
    var textBlinkPhase = true
    var hasBlinkingCells = false
    private var rowHasBlinkingCells: [Bool] = []
    private var blinkingRowCount = 0

    struct CursorRenderState: Equatable {
        let row: Int
        let col: Int
        let style: String
        let color: SIMD4<Float>
    }

    private var lastCursorRenderState: CursorRenderState?

    // MARK: - Clear Color (from color scheme)

    var clearColor: (r: Float, g: Float, b: Float) = (0.0, 0.0, 0.0)

    /// Uniforms passed to GPU each frame.
    struct Uniforms {
        var projectionMatrix: simd_float4x4
        var atlasSize: SIMD2<Float>
        var cellSize: SIMD2<Float>
        var viewportSize: SIMD2<Float>
        var scaleFactor: Float
        var blinkVisible: Float // text blink: 1.0 = show, 0.0 = hide
        var underlineY: Float
        var cursorBlinkVisible: Float // cursor blink: 1.0 = show, 0.0 = hide
        var cols: UInt32
        var _pad: (UInt32, UInt32, UInt32) = (0, 0, 0)
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

        do {
            try setupPipeline()
            setupStaticBuffers()
            setupAtlasContext()
        } catch {
            Log.error("MetalRenderer: Setup failed: \(error)")
            return nil
        }
    }

    // MARK: - Setup

    private func setupPipeline() throws {
        let deviceKey = ObjectIdentifier(device)
        if let (cached, _) = Self.pipelineCache[deviceKey] {
            pipelineState = cached
            return
        }

        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)

        guard let vertexFunction = library.makeFunction(name: "vertexShader"),
              let fragmentFunction = library.makeFunction(name: "fragmentShader") else {
            throw MetalError.shaderCompilationFailed
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        // Single-pass outputs fully composited opaque pixels — no blending needed.
        descriptor.colorAttachments[0].isBlendingEnabled = false

        pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        Self.pipelineCache[deviceKey] = (pipelineState, library)
    }

    private func setupStaticBuffers() {
        let uniformSize = MemoryLayout<Uniforms>.stride
        uniformBuffer = device.makeBuffer(length: uniformSize, options: .storageModeShared)

        let vertices: [SIMD2<Float>] = [
            SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1), SIMD2(1, 1)
        ]
        vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: vertices.count * MemoryLayout<SIMD2<Float>>.stride,
            options: .storageModeShared
        )
    }

    /// Ensures ring buffers can hold at least `cellCount` instances.
    /// Allocates or grows the ring if needed.
    func ensureCapacity(cells cellCount: Int) {
        guard cellCount > cellCapacity else { return }
        let newCapacity = max(cellCount, cellCapacity * 2, 16000) // grow by 2× or 16K minimum
        let byteSize = newCapacity * MemoryLayout<CellInstance>.stride

        instanceBuffers = (0 ..< Self.ringBufferCount).compactMap { _ in
            device.makeBuffer(length: byteSize, options: .storageModeShared)
        }
        guard instanceBuffers.count == Self.ringBufferCount else {
            Log.error("MetalRenderer: Failed to allocate ring buffers")
            return
        }
        cellCapacity = newCapacity
        ringIndex = 0
        Log.info("MetalRenderer: Ring buffers allocated for \(newCapacity) cells (\(byteSize / 1024) KB each)")
    }

    /// Returns the current write-target instance buffer and advances the ring.
    func nextInstanceBuffer() -> MTLBuffer {
        let buffer = instanceBuffers[ringIndex]
        ringIndex = (ringIndex + 1) % Self.ringBufferCount
        return buffer
    }

    // MARK: - Atlas

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
        atlasContext?.setShouldSmoothFonts(false)
        atlasContext?.setShouldAntialias(true)
        atlasContext?.setAllowsFontSubpixelPositioning(true)
        atlasContext?.setShouldSubpixelPositionFonts(true)
    }

    // MARK: - Font Configuration

    func setFont(nsFont: NSFont, scaleFactor: CGFloat = 1.0) {
        fontSize = nsFont.pointSize
        self.scaleFactor = scaleFactor

        let scaledSize = nsFont.pointSize * scaleFactor
        let baseCTFont = nsFont as CTFont
        regularFont = CTFontCreateCopyWithAttributes(baseCTFont, scaledSize, nil, nil)

        let boldTraits: CTFontSymbolicTraits = .boldTrait
        let italicTraits: CTFontSymbolicTraits = .italicTrait
        let boldItalicTraits: CTFontSymbolicTraits = [.boldTrait, .italicTrait]

        boldFont = CTFontCreateCopyWithSymbolicTraits(regularFont, scaledSize, nil, boldTraits, boldTraits)
            ?? regularFont
        italicFont = CTFontCreateCopyWithSymbolicTraits(regularFont, scaledSize, nil, italicTraits, italicTraits)
            ?? regularFont
        boldItalicFont = CTFontCreateCopyWithSymbolicTraits(regularFont, scaledSize, nil, boldItalicTraits, boldItalicTraits)
            ?? regularFont

        let pointCellSize = TerminalFont.cellSize(for: nsFont)
        cellSize = CGSize(
            width: pointCellSize.width * scaleFactor,
            height: pointCellSize.height * scaleFactor
        )

        fontAscent = CTFontGetAscent(regularFont)
        fontDescent = CTFontGetDescent(regularFont)

        let baseCT = nsFont as CTFont
        let ptAscent = CTFontGetAscent(baseCT)
        let ulOffset = CTFontGetUnderlinePosition(baseCT)
        let baselineFrac = ptAscent / pointCellSize.height
        let ulFrac = baselineFrac - ulOffset / pointCellSize.height
        underlinePosition = Float(min(max(ulFrac, 0.7), 0.95))

        guard cellSize.width > 0, cellSize.height > 0 else {
            Log.error("MetalRenderer: Zero cell size from font \(CTFontCopyFullName(regularFont))")
            return
        }

        resetAtlas()
        prerasterizeASCII()
        uploadAtlasTexture()
        Log.trace("MetalRenderer: Font configured — scaledSize=\(scaledSize), cellSize=\(cellSize), atlas=\(glyphCache.count) glyphs")
    }

    // MARK: - Atlas Management

    private func resetAtlas() {
        glyphCache.removeAll()
        ligatureCache.removeAll()
        ligatureCacheInsertionOrder.removeAll(keepingCapacity: false)
        asciiGlyphs = Array(repeating: nil, count: Int(Self.asciiCount) * Self.styleVariants)
        packX = 0
        packY = 0
        packRowHeight = 0
        atlasDirty = false
        atlasContext?.clear(CGRect(x: 0, y: 0, width: atlasWidth, height: atlasHeight))
    }

    private func prerasterizeASCII() {
        let styles: [(bold: Bool, italic: Bool)] = [
            (false, false), (true, false), (false, true), (true, true)
        ]
        for style in styles {
            for cp: UInt32 in Self.asciiBase ... (Self.asciiBase + Self.asciiCount - 1) {
                if let info = rasterizeGlyph(codePoint: cp, bold: style.bold, italic: style.italic) {
                    let styleIndex = (style.bold ? 1 : 0) + (style.italic ? 2 : 0)
                    let arrayIndex = Int(cp - Self.asciiBase) * Self.styleVariants + styleIndex
                    asciiGlyphs[arrayIndex] = info
                }
            }
        }
    }

    // MARK: - Glyph Rasterization

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

        var drawFont = font
        let found = CTFontGetGlyphsForCharacters(font, &unichars, &glyphs, unichars.count)

        if !found || glyphs[0] == 0 {
            let fallback = CTFontCreateForString(font, charStr as CFString, CFRangeMake(0, charStr.utf16.count))
            CTFontGetGlyphsForCharacters(fallback, &unichars, &glyphs, unichars.count)
            if glyphs[0] != 0 {
                drawFont = fallback
            }
        }

        var advanceSize = CGSize.zero
        CTFontGetAdvancesForGlyphs(drawFont, .horizontal, &glyphs, &advanceSize, 1)
        let isWide = advanceSize.width > cellSize.width * 1.3

        let slotWidth = isWide ? cellSize.width * 2 : cellSize.width
        let slotHeight = cellSize.height
        let padding: CGFloat = 2

        if packX + slotWidth + padding > CGFloat(atlasWidth) {
            packX = 0
            packY += packRowHeight + padding
            packRowHeight = 0
        }

        if packY + slotHeight > CGFloat(atlasHeight) {
            Log.warn("MetalRenderer: Glyph atlas full, resetting and rebuilding ASCII baseline")
            resetAtlas()
            prerasterizeASCII()
            uploadAtlasTexture()
            if packY + slotHeight > CGFloat(atlasHeight) {
                Log.error("MetalRenderer: Atlas still full after reset")
                return nil
            }
        }

        packRowHeight = max(packRowHeight, slotHeight)

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        let baselineY = CGFloat(atlasHeight) - packY - slotHeight + fontDescent
        var position = CGPoint(x: packX, y: baselineY)
        CTFontDrawGlyphs(drawFont, glyphs, &position, 1, context)

        let texRect = CGRect(
            x: packX / CGFloat(atlasWidth),
            y: packY / CGFloat(atlasHeight),
            width: slotWidth / CGFloat(atlasWidth),
            height: slotHeight / CGFloat(atlasHeight)
        )

        let info = GlyphInfo(
            textureRect: texRect,
            isWide: isWide
        )
        glyphCache[key] = info

        packX += slotWidth + padding
        atlasDirty = true
        return info
    }

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

    // MARK: - Glyph Lookup (ASCII fast-path + hash fallback)

    /// Looks up a glyph, using the flat ASCII array for common characters
    /// and falling back to the dictionary for Unicode.
    @inline(__always)
    func lookupGlyph(codePoint: UInt32, bold: Bool, italic: Bool) -> GlyphInfo? {
        glyphLookupCount += 1

        // ASCII fast-path: direct array index, no hashing
        if codePoint >= Self.asciiBase, codePoint < Self.asciiBase + Self.asciiCount {
            let styleIndex = (bold ? 1 : 0) + (italic ? 2 : 0)
            let arrayIndex = Int(codePoint - Self.asciiBase) * Self.styleVariants + styleIndex
            if let info = asciiGlyphs[arrayIndex] { return info }
        }

        // Dictionary lookup for Unicode
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
        return asciiGlyphs[0] // space, regular style
    }

    // MARK: - Ligature Rendering

    func lookupLigature(sequence: String, bold: Bool, italic: Bool) -> LigatureInfo? {
        let key = LigatureKey(sequence: sequence, bold: bold, italic: italic)
        if let cached = ligatureCache[key] {
            switch cached {
            case .miss: return nil
            case let .hit(info): return info
            }
        }

        let font: CTFont
        switch (bold, italic) {
        case (true, true): font = boldItalicFont
        case (true, false): font = boldFont
        case (false, true): font = italicFont
        case (false, false): font = regularFont
        }

        let attrString = NSAttributedString(string: sequence, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attrString)
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        guard let run = runs.first else {
            cacheLigature(.miss, for: key)
            return nil
        }

        let glyphCount = CTRunGetGlyphCount(run)
        if glyphCount >= sequence.count {
            cacheLigature(.miss, for: key)
            return nil
        }

        let cellSpan = sequence.count
        let slotWidth = cellSize.width * CGFloat(cellSpan)
        let slotHeight = cellSize.height
        let padding: CGFloat = 2

        if packX + slotWidth + padding > CGFloat(atlasWidth) {
            packX = 0
            packY += packRowHeight + padding
            packRowHeight = 0
        }
        if packY + slotHeight > CGFloat(atlasHeight) {
            cacheLigature(.miss, for: key)
            return nil
        }
        packRowHeight = max(packRowHeight, slotHeight)

        guard let context = atlasContext else {
            cacheLigature(.miss, for: key)
            return nil
        }
        let baselineY = CGFloat(atlasHeight) - packY - slotHeight + fontDescent
        let origin = CGPoint(x: packX, y: baselineY)

        context.saveGState()
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
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
    }

    private static let maxLigatureLength = 3

    /// Try to form a ligature from consecutive cells starting at index.
    func tryLigature(
        cells: UnsafePointer<RustCellData>,
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
                let cp = c.character
                guard cp >= 0x21, cp < 0x7F, let scalar = Unicode.Scalar(cp) else {
                    valid = false
                    break
                }
                let cBold = (c.flags & RustCellFlags.bold) != 0
                let cItalic = (c.flags & RustCellFlags.italic) != 0
                if cBold != bold || cItalic != italic { valid = false
                    break
                }
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

    /// Submits a single-pass draw call for the given instance buffer.
    func render(
        instanceBuffer: MTLBuffer,
        cellCount: Int,
        rows: Int,
        cols: Int,
        to drawable: CAMetalDrawable,
        viewportSize: CGSize
    ) {
        guard cellCount > 0 else { return }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        // Upload atlas if new glyphs were rasterized this frame
        if atlasDirty { uploadAtlasTexture() }

        updateUniforms(viewportSize: viewportSize, cols: cols)

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = drawable.texture
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].storeAction = .store
        passDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(
            Double(clearColor.r), Double(clearColor.g), Double(clearColor.b), 1.0
        )

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else { return }

        // Single pass: background + glyph + decorations
        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 1)
        encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 2)
        encoder.setFragmentTexture(glyphAtlas, index: 0)
        encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 2)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: cellCount)

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func updateUniforms(viewportSize: CGSize, cols: Int) {
        let uniforms = uniformBuffer.contents().bindMemory(to: Uniforms.self, capacity: 1)

        let projectionMatrix = simd_float4x4(
            orthographicLeft: 0,
            right: Float(viewportSize.width),
            bottom: Float(viewportSize.height),
            top: 0,
            near: -1,
            far: 1
        )

        let showCursor = cursorVisible && (!cursorBlinkEnabled || cursorBlinkPhase)
        uniforms.pointee = Uniforms(
            projectionMatrix: projectionMatrix,
            atlasSize: SIMD2(Float(atlasWidth), Float(atlasHeight)),
            cellSize: SIMD2(Float(cellSize.width / scaleFactor), Float(cellSize.height / scaleFactor)),
            viewportSize: SIMD2(Float(viewportSize.width), Float(viewportSize.height)),
            scaleFactor: Float(scaleFactor),
            blinkVisible: textBlinkPhase ? 1.0 : 0.0,
            underlineY: underlinePosition,
            cursorBlinkVisible: showCursor ? 1.0 : 0.0,
            cols: UInt32(cols)
        )
    }

    // MARK: - Blink Row Tracking

    func resetBlinkTracking(rows: Int) {
        rowHasBlinkingCells = Array(repeating: false, count: rows)
        blinkingRowCount = 0
        hasBlinkingCells = false
    }

    func updateBlinkForRow(_ row: Int, hasBlink: Bool) {
        guard row < rowHasBlinkingCells.count else { return }
        if rowHasBlinkingCells[row] != hasBlink {
            blinkingRowCount += hasBlink ? 1 : -1
            rowHasBlinkingCells[row] = hasBlink
        }
    }

    func finalizeBlinkState() {
        hasBlinkingCells = blinkingRowCount > 0
    }

    // MARK: - Cursor

    func currentCursorRenderState(cellCount: Int, cols: Int) -> CursorRenderState? {
        guard cols > 0, cursorVisible else { return nil }
        // Always write cursor data — the shader uses cursorBlinkVisible uniform
        // to show/hide. This lets present-only redraws toggle cursor blink
        // without re-building instance data.
        let cursorIndex = cursorRow * cols + cursorCol
        guard cursorIndex >= 0, cursorIndex < cellCount else { return nil }
        return CursorRenderState(row: cursorRow, col: cursorCol, style: cursorStyle, color: cursorColor)
    }

    func applyCursor(
        to instances: UnsafeMutablePointer<CellInstance>,
        cellCount: Int,
        cols: Int,
        cursorState: CursorRenderState?
    ) {
        guard let cursorState, cols > 0 else {
            lastCursorRenderState = nil
            return
        }
        let cursorIndex = cursorState.row * cols + cursorState.col
        guard cursorIndex >= 0, cursorIndex < cellCount else {
            lastCursorRenderState = cursorState
            return
        }

        var flags = instances[cursorIndex].flags | (1 << 5)
        switch cursorState.style {
        case "underline": flags |= (1 << 6)
        case "bar": flags |= (2 << 6)
        default: break
        }
        instances[cursorIndex].flags = flags
        // Pack cursor color as fg for the cursor cell
        instances[cursorIndex].colors.x = CellInstance.packColor(
            cursorState.color.x, cursorState.color.y, cursorState.color.z, cursorState.color.w
        )
        lastCursorRenderState = cursorState
    }

    /// Rows that need instance buffer update due to cursor movement.
    func cursorDirtyRows(currentState: CursorRenderState?, totalRows: Int) -> IndexSet {
        var rows = IndexSet()
        let needsRefresh = lastCursorRenderState != currentState
        guard needsRefresh else { return rows }
        if let prev = lastCursorRenderState, prev.row >= 0, prev.row < totalRows {
            rows.insert(prev.row)
        }
        if let curr = currentState, curr.row >= 0, curr.row < totalRows {
            rows.insert(curr.row)
        }
        return rows
    }

    // MARK: - Purgeable / Memory Volatility

    func setAtlasPurgeableState(_ state: MTLPurgeableState) -> MTLPurgeableState {
        let atlasPrior = glyphAtlas?.setPurgeableState(state) ?? .keepCurrent
        for buffer in instanceBuffers {
            _ = buffer.setPurgeableState(state)
        }
        _ = uniformBuffer?.setPurgeableState(state)
        _ = vertexBuffer?.setPurgeableState(state)
        return atlasPrior
    }

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

// MARK: - Single-Pass Shader

extension MetalTerminalRenderer {
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct CellInstance {
        float4 texCoord;    // u, v, width, height
        uint2 colors;       // .x = packed fg RGBA, .y = packed bg RGBA
        uint flags;
        uint _pad;
    };

    struct Uniforms {
        float4x4 projectionMatrix;
        float2 atlasSize;
        float2 cellSize;
        float2 viewportSize;
        float scaleFactor;
        float blinkVisible;
        float underlineY;
        float cursorBlinkVisible;
        uint cols;
        uint _pad1;
        uint _pad2;
        uint _pad3;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 texCoord;
        float2 cellLocalPos;
        float4 foreground;
        float4 background;
        uint flags;
    };

    vertex VertexOut vertexShader(
        uint vertexID [[vertex_id]],
        uint instanceID [[instance_id]],
        constant float2* vertices [[buffer(0)]],
        constant CellInstance* instances [[buffer(1)]],
        constant Uniforms& uniforms [[buffer(2)]]
    ) {
        CellInstance cell = instances[instanceID];

        // Compute grid position from instanceID — no per-cell position stored
        uint col = instanceID % uniforms.cols;
        uint row = instanceID / uniforms.cols;
        float2 cellOrigin = float2(float(col), float(row)) * uniforms.cellSize;

        float2 vertexPos = vertices[vertexID];
        float2 worldPos = cellOrigin + vertexPos * uniforms.cellSize;
        float2 texCoord = cell.texCoord.xy + vertexPos * cell.texCoord.zw;

        // Unpack u8x4 colors to float4
        float4 fg = unpack_unorm4x8_to_float(cell.colors.x);
        float4 bg = unpack_unorm4x8_to_float(cell.colors.y);

        VertexOut out;
        out.position = uniforms.projectionMatrix * float4(worldPos, 0.0, 1.0);
        out.texCoord = texCoord;
        out.cellLocalPos = vertexPos;
        out.foreground = fg;
        out.background = bg;
        out.flags = cell.flags;
        return out;
    }

    fragment float4 fragmentShader(
        VertexOut in [[stage_in]],
        texture2d<float> glyphAtlas [[texture(0)]],
        constant Uniforms& uniforms [[buffer(2)]]
    ) {
        constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
        float4 texColor = glyphAtlas.sample(textureSampler, in.texCoord);
        float glyphAlpha = texColor.a;

        // Text blink: when blinking text is hidden, render background only
        bool isBlink = (in.flags & 16u) != 0;
        if (isBlink && uniforms.blinkVisible < 0.5) {
            return in.background;
        }

        // Cursor state — cursor blink is handled via uniform, not instance data
        bool hasCursor = (in.flags & (1u << 5)) != 0;
        if (hasCursor && uniforms.cursorBlinkVisible < 0.5) {
            hasCursor = false; // cursor is in blink-off phase
        }
        uint cursorStyle = (in.flags >> 6) & 3u;

        // Single-pass compositing: mix background and foreground via glyph alpha.
        // This is mathematically identical to "draw bg quad then alpha-blend glyph"
        // but avoids a second draw call and disables GPU blending entirely.
        float4 color;

        if (hasCursor && cursorStyle == 0) {
            // Block cursor: foreground fills cell, glyph punches through in bg color
            color = mix(in.foreground, float4(in.background.rgb, 1.0), glyphAlpha);
        } else {
            // Normal: background base, glyph blended on top in foreground color
            color = mix(in.background, float4(in.foreground.rgb, 1.0), glyphAlpha);
        }

        // Cursor underline/bar (drawn over everything)
        if (hasCursor && cursorStyle == 1 && in.cellLocalPos.y > 0.9) {
            return in.foreground;
        }
        if (hasCursor && cursorStyle == 2 && in.cellLocalPos.x < 0.08) {
            return in.foreground;
        }

        // Decoration thickness: ~2 device pixels
        float thickness = 2.0 / (uniforms.cellSize.y * uniforms.scaleFactor);

        // Underline (bit 2), variant in bits 8-10
        if ((in.flags & 4u) != 0) {
            uint ulVariant = (in.flags >> 8) & 7u;
            float underlineY = uniforms.underlineY;

            if (ulVariant == 2u) {
                float gap = thickness * 1.5;
                float line1Y = underlineY;
                float line2Y = underlineY + thickness + gap;
                bool onLine1 = (in.cellLocalPos.y > line1Y && in.cellLocalPos.y < line1Y + thickness);
                bool onLine2 = (in.cellLocalPos.y > line2Y && in.cellLocalPos.y < line2Y + thickness);
                if (onLine1 || onLine2) { return float4(in.foreground.rgb, 1.0); }
            } else if (ulVariant == 3u) {
                float amplitude = thickness * 2.0;
                float freq = 3.14159 * 4.0;
                float wave = underlineY + amplitude * sin(in.cellLocalPos.x * freq);
                if (abs(in.cellLocalPos.y - wave) < thickness) { return float4(in.foreground.rgb, 1.0); }
            } else if (ulVariant == 4u) {
                bool onY = (in.cellLocalPos.y > underlineY && in.cellLocalPos.y < underlineY + thickness);
                float dotPeriod = 0.08;
                if (onY && fmod(in.cellLocalPos.x, dotPeriod) < (dotPeriod * 0.5)) { return float4(in.foreground.rgb, 1.0); }
            } else if (ulVariant == 5u) {
                bool onY = (in.cellLocalPos.y > underlineY && in.cellLocalPos.y < underlineY + thickness);
                float dashPeriod = 0.2;
                if (onY && fmod(in.cellLocalPos.x, dashPeriod) < (dashPeriod * 0.7)) { return float4(in.foreground.rgb, 1.0); }
            } else {
                if (in.cellLocalPos.y > underlineY && in.cellLocalPos.y < underlineY + thickness) {
                    return float4(in.foreground.rgb, 1.0);
                }
            }
        }

        // Strikethrough (bit 3)
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
