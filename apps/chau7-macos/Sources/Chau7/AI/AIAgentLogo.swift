import AppKit
import SwiftUI

/// AI agents that the app can detect and display logos for.
enum AIAgent: String, CaseIterable {
    case claude = "Claude"
    case gemini = "Gemini"
    case codex = "Codex"
    case chatGPT = "ChatGPT"
    case copilot = "Copilot"
    case aider = "Aider"
    case cursor = "Cursor"

    /// Expected filename for the logo in Resources (e.g., "claude-logo.png")
    var logoFileName: String {
        "\(rawValue.lowercased())-logo"
    }

    /// Brand color associated with this AI agent
    var brandColor: NSColor {
        switch self {
        case .claude:
            return NSColor(calibratedRed: 0.85, green: 0.55, blue: 0.35, alpha: 1.0)  // Claude orange/tan
        case .gemini:
            return NSColor(calibratedRed: 0.27, green: 0.53, blue: 0.93, alpha: 1.0)  // Google blue
        case .codex:
            return NSColor(calibratedRed: 0.0, green: 0.65, blue: 0.52, alpha: 1.0)   // OpenAI green
        case .chatGPT:
            return NSColor(calibratedRed: 0.0, green: 0.65, blue: 0.52, alpha: 1.0)   // OpenAI green
        case .copilot:
            return NSColor(calibratedRed: 0.15, green: 0.15, blue: 0.15, alpha: 1.0)  // GitHub dark
        case .aider:
            return NSColor(calibratedRed: 0.93, green: 0.46, blue: 0.6, alpha: 1.0)   // Pink
        case .cursor:
            return NSColor(calibratedRed: 0.2, green: 0.68, blue: 0.66, alpha: 1.0)   // Teal
        }
    }

    /// SwiftUI color for the brand
    var swiftUIColor: Color {
        Color(nsColor: brandColor)
    }

    /// Creates the agent from a detected app name string
    static func from(appName: String) -> AIAgent? {
        allCases.first { $0.rawValue.lowercased() == appName.lowercased() }
    }
}

/// Handles loading and generating AI agent logos for tab display.
enum AIAgentLogo {
    private static var logoCache: [AIAgent: NSImage] = [:]
    private static let logoSize = NSSize(width: 16, height: 16)

    /// Returns the logo for an AI agent, using cached version if available.
    /// Loads from bundle resources first, falls back to programmatic generation.
    static func logo(for agent: AIAgent) -> NSImage {
        if let cached = logoCache[agent] {
            return cached
        }
        let image = loadFromFile(agent: agent) ?? generateLogo(for: agent)
        logoCache[agent] = image
        return image
    }

    /// Attempts to load logo from bundle resources
    private static func loadFromFile(agent: AIAgent) -> NSImage? {
        // Try resource bundle first (for SwiftPM resources)
        if let url = Chau7Resources.bundle.url(forResource: agent.logoFileName, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = logoSize
            return image
        }

        // Try main bundle next (for .app builds with direct resources)
        if let url = Bundle.main.url(forResource: agent.logoFileName, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = logoSize
            return image
        }

        // For debug builds, look relative to executable location
        let executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let debugResourcesURL = executableURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Chau7/Resources/\(agent.logoFileName).png")

        if FileManager.default.fileExists(atPath: debugResourcesURL.path),
           let image = NSImage(contentsOf: debugResourcesURL) {
            image.size = logoSize
            return image
        }

        return nil
    }

    /// Generates a programmatic logo approximation for each AI agent
    private static func generateLogo(for agent: AIAgent) -> NSImage {
        let size = logoSize
        let image = NSImage(size: size)

        image.lockFocus()
        defer { image.unlockFocus() }

        let rect = NSRect(origin: .zero, size: size)
        let brandColor = agent.brandColor

        switch agent {
        case .claude:
            drawClaudeLogo(in: rect, color: brandColor)
        case .gemini:
            drawGeminiLogo(in: rect, color: brandColor)
        case .codex:
            drawCodexLogo(in: rect, color: brandColor)
        case .chatGPT:
            drawChatGPTLogo(in: rect, color: brandColor)
        case .copilot:
            drawCopilotLogo(in: rect, color: brandColor)
        case .aider:
            drawAiderLogo(in: rect, color: brandColor)
        case .cursor:
            drawCursorLogo(in: rect, color: brandColor)
        }

        return image
    }

    // MARK: - Logo Drawing Methods

    /// Claude: Simplified representation with rounded shape
    private static func drawClaudeLogo(in rect: NSRect, color: NSColor) {
        let inset = rect.insetBy(dx: 1, dy: 1)

        // Main rounded square background
        let bgPath = NSBezierPath(roundedRect: inset, xRadius: 4, yRadius: 4)
        color.setFill()
        bgPath.fill()

        // Simplified "C" letterform
        let centerX = rect.midX
        let centerY = rect.midY
        let radius: CGFloat = 4.5

        let arcPath = NSBezierPath()
        arcPath.appendArc(
            withCenter: NSPoint(x: centerX, y: centerY),
            radius: radius,
            startAngle: 45,
            endAngle: 315,
            clockwise: false
        )
        arcPath.lineWidth = 2.5
        NSColor.white.setStroke()
        arcPath.stroke()
    }

    /// Gemini: Four-pointed star/sparkle shape
    private static func drawGeminiLogo(in rect: NSRect, color: NSColor) {
        let centerX = rect.midX
        let centerY = rect.midY
        let outerRadius: CGFloat = 7
        let innerRadius: CGFloat = 2.5

        let starPath = NSBezierPath()
        for i in 0..<8 {
            let radius = i % 2 == 0 ? outerRadius : innerRadius
            let angle = CGFloat(i) * .pi / 4 - .pi / 2
            let point = NSPoint(
                x: centerX + cos(angle) * radius,
                y: centerY + sin(angle) * radius
            )
            if i == 0 {
                starPath.move(to: point)
            } else {
                starPath.line(to: point)
            }
        }
        starPath.close()
        color.setFill()
        starPath.fill()
    }

    /// Codex: Code brackets representation
    private static func drawCodexLogo(in rect: NSRect, color: NSColor) {
        let inset = rect.insetBy(dx: 2, dy: 3)

        // Left bracket <
        let leftPath = NSBezierPath()
        leftPath.move(to: NSPoint(x: inset.minX + 5, y: inset.minY))
        leftPath.line(to: NSPoint(x: inset.minX, y: inset.midY))
        leftPath.line(to: NSPoint(x: inset.minX + 5, y: inset.maxY))
        leftPath.lineWidth = 2
        color.setStroke()
        leftPath.stroke()

        // Right bracket >
        let rightPath = NSBezierPath()
        rightPath.move(to: NSPoint(x: inset.maxX - 5, y: inset.minY))
        rightPath.line(to: NSPoint(x: inset.maxX, y: inset.midY))
        rightPath.line(to: NSPoint(x: inset.maxX - 5, y: inset.maxY))
        rightPath.lineWidth = 2
        rightPath.stroke()

        // Center slash
        let slashPath = NSBezierPath()
        slashPath.move(to: NSPoint(x: inset.midX + 2, y: inset.minY))
        slashPath.line(to: NSPoint(x: inset.midX - 2, y: inset.maxY))
        slashPath.lineWidth = 1.5
        slashPath.stroke()
    }

    /// ChatGPT: Hexagonal flower pattern
    private static func drawChatGPTLogo(in rect: NSRect, color: NSColor) {
        let centerX = rect.midX
        let centerY = rect.midY
        let petalRadius: CGFloat = 3
        let distance: CGFloat = 4

        // Draw 6 petals in hexagonal arrangement
        for i in 0..<6 {
            let angle = CGFloat(i) * .pi / 3
            let petalCenter = NSPoint(
                x: centerX + cos(angle) * distance,
                y: centerY + sin(angle) * distance
            )
            let petalRect = NSRect(
                x: petalCenter.x - petalRadius,
                y: petalCenter.y - petalRadius,
                width: petalRadius * 2,
                height: petalRadius * 2
            )
            let petalPath = NSBezierPath(ovalIn: petalRect)
            color.setFill()
            petalPath.fill()
        }

        // Center circle
        let centerRect = NSRect(x: centerX - 2, y: centerY - 2, width: 4, height: 4)
        let centerPath = NSBezierPath(ovalIn: centerRect)
        color.setFill()
        centerPath.fill()
    }

    /// Copilot: Stylized pilot/aviation icon
    private static func drawCopilotLogo(in rect: NSRect, color: NSColor) {
        let inset = rect.insetBy(dx: 1, dy: 1)

        // Background circle
        let bgPath = NSBezierPath(ovalIn: inset)
        color.setFill()
        bgPath.fill()

        // Simplified pilot goggles/visor
        let visorRect = NSRect(x: inset.minX + 3, y: inset.midY - 1.5, width: inset.width - 6, height: 4)
        let visorPath = NSBezierPath(roundedRect: visorRect, xRadius: 2, yRadius: 2)
        NSColor.white.setFill()
        visorPath.fill()

        // Two eye circles within visor
        let eyeSize: CGFloat = 3
        let leftEye = NSRect(x: visorRect.minX + 1, y: visorRect.midY - eyeSize / 2, width: eyeSize, height: eyeSize)
        let rightEye = NSRect(x: visorRect.maxX - eyeSize - 1, y: visorRect.midY - eyeSize / 2, width: eyeSize, height: eyeSize)
        color.setFill()
        NSBezierPath(ovalIn: leftEye).fill()
        NSBezierPath(ovalIn: rightEye).fill()
    }

    /// Aider: Wrench/tool representation
    private static func drawAiderLogo(in rect: NSRect, color: NSColor) {
        let inset = rect.insetBy(dx: 2, dy: 2)

        // Background rounded rect
        let bgPath = NSBezierPath(roundedRect: inset, xRadius: 3, yRadius: 3)
        color.setFill()
        bgPath.fill()

        // Simplified "A" letterform
        let aPath = NSBezierPath()
        aPath.move(to: NSPoint(x: inset.minX + 2, y: inset.minY + 2))
        aPath.line(to: NSPoint(x: inset.midX, y: inset.maxY - 2))
        aPath.line(to: NSPoint(x: inset.maxX - 2, y: inset.minY + 2))
        aPath.lineWidth = 2
        NSColor.white.setStroke()
        aPath.stroke()

        // Crossbar
        let crossbar = NSBezierPath()
        crossbar.move(to: NSPoint(x: inset.minX + 4, y: inset.midY - 1))
        crossbar.line(to: NSPoint(x: inset.maxX - 4, y: inset.midY - 1))
        crossbar.lineWidth = 1.5
        crossbar.stroke()
    }

    /// Cursor: Arrow cursor icon
    private static func drawCursorLogo(in rect: NSRect, color: NSColor) {
        let inset = rect.insetBy(dx: 2, dy: 1)

        // Arrow cursor shape
        let arrowPath = NSBezierPath()
        arrowPath.move(to: NSPoint(x: inset.minX, y: inset.maxY))  // Top left (point)
        arrowPath.line(to: NSPoint(x: inset.minX, y: inset.minY))  // Bottom left
        arrowPath.line(to: NSPoint(x: inset.minX + 8, y: inset.minY + 5))  // Right middle
        arrowPath.line(to: NSPoint(x: inset.minX + 4, y: inset.minY + 5))  // Notch
        arrowPath.line(to: NSPoint(x: inset.minX + 7, y: inset.minY))  // Handle bottom
        arrowPath.line(to: NSPoint(x: inset.minX + 5, y: inset.minY))  // Handle left
        arrowPath.line(to: NSPoint(x: inset.minX + 3, y: inset.minY + 4))  // Back to notch
        arrowPath.close()

        color.setFill()
        arrowPath.fill()

        // White outline for visibility
        arrowPath.lineWidth = 0.5
        NSColor.white.withAlphaComponent(0.8).setStroke()
        arrowPath.stroke()
    }
}

// MARK: - SwiftUI Integration

extension AIAgentLogo {
    /// Returns a SwiftUI Image for the specified agent
    static func image(for agent: AIAgent) -> Image {
        Image(nsImage: logo(for: agent))
    }

    /// Returns a SwiftUI Image for the specified app name, or nil if not recognized
    static func image(forAppName appName: String) -> Image? {
        guard let agent = AIAgent.from(appName: appName) else { return nil }
        return image(for: agent)
    }
}
