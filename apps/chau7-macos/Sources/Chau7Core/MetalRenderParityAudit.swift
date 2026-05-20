public enum MetalRenderParityFeature: String, CaseIterable, Hashable, Sendable {
    case wideGlyphs
    case emojiFallbackFonts
    case ligatures
    case osc8LinkUnderline
    case selection
    case inlineImages
    case commandBlockTinting
}

public enum MetalRenderParityStatus: String, Equatable, Sendable {
    case covered
    case partial
    case externalOverlay
    case knownGap
}

public struct MetalRenderParityAuditEntry: Equatable, Sendable {
    public let feature: MetalRenderParityFeature
    public let status: MetalRenderParityStatus
    public let note: String
}

public enum MetalRenderParityAudit {
    public static let entries: [MetalRenderParityAuditEntry] = [
        MetalRenderParityAuditEntry(
            feature: .wideGlyphs,
            status: .partial,
            note: "Metal rasterizes wide glyphs through the atlas, but cell-span visual parity still needs snapshot coverage."
        ),
        MetalRenderParityAuditEntry(
            feature: .emojiFallbackFonts,
            status: .partial,
            note: "CoreText fallback rasterization is active; emoji/color-font parity remains visual-QA dependent."
        ),
        MetalRenderParityAuditEntry(
            feature: .ligatures,
            status: .partial,
            note: "Metal has a ligature cache path, but terminal cell-span parity needs broader fixture coverage."
        ),
        MetalRenderParityAuditEntry(
            feature: .osc8LinkUnderline,
            status: .covered,
            note: "Rust link IDs without explicit SGR underline now set a Metal link-underline flag."
        ),
        MetalRenderParityAuditEntry(
            feature: .selection,
            status: .partial,
            note: "Selection colors flow through cell colors, but selection-edge and mixed-style parity need snapshot coverage."
        ),
        MetalRenderParityAuditEntry(
            feature: .inlineImages,
            status: .externalOverlay,
            note: "Inline images are managed by the terminal image overlay layer rather than Metal cell instances."
        ),
        MetalRenderParityAuditEntry(
            feature: .commandBlockTinting,
            status: .covered,
            note: "Viewport row tints are blended in the Metal bridge before cells enter the triple buffer."
        )
    ]

    public static func entry(for feature: MetalRenderParityFeature) -> MetalRenderParityAuditEntry? {
        entries.first { $0.feature == feature }
    }
}
