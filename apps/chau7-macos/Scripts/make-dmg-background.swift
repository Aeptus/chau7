#!/usr/bin/env swift

import AppKit
import Foundation

guard CommandLine.arguments.count >= 3 else {
    fputs("Usage: make-dmg-background.swift <output.png> <icon.png>\n", stderr)
    exit(1)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
_ = URL(fileURLWithPath: CommandLine.arguments[2])

let size = NSSize(width: 720, height: 460)
let rect = NSRect(origin: .zero, size: size)

let image = NSImage(size: size)
image.lockFocus()

guard let ctx = NSGraphicsContext.current?.cgContext else {
    fputs("Unable to create graphics context\n", stderr)
    exit(1)
}

ctx.setFillColor(NSColor(calibratedRed: 0.96, green: 0.95, blue: 0.92, alpha: 1).cgColor)
ctx.fill(rect)

let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.98, green: 0.97, blue: 0.94, alpha: 1),
    NSColor(calibratedRed: 0.91, green: 0.95, blue: 0.93, alpha: 1),
])
gradient?.draw(in: rect, angle: -18)

let highlightRect = NSRect(x: 34, y: 34, width: size.width - 68, height: size.height - 68)
let highlightPath = NSBezierPath(roundedRect: highlightRect, xRadius: 30, yRadius: 30)
NSColor(calibratedWhite: 1.0, alpha: 0.50).setFill()
highlightPath.fill()

let leftCard = NSRect(x: 84, y: 134, width: 188, height: 188)
let rightCard = NSRect(x: 448, y: 134, width: 188, height: 188)
for card in [leftCard, rightCard] {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.12)
    shadow.shadowBlurRadius = 18
    shadow.shadowOffset = NSSize(width: 0, height: -5)
    shadow.set()

    let path = NSBezierPath(roundedRect: card, xRadius: 28, yRadius: 28)
    NSColor(calibratedWhite: 1.0, alpha: 0.88).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
}

NSGraphicsContext.saveGraphicsState()
let arrowPath = NSBezierPath()
arrowPath.lineWidth = 8
arrowPath.lineCapStyle = .round
arrowPath.lineJoinStyle = .round
arrowPath.move(to: NSPoint(x: 304, y: 228))
arrowPath.curve(to: NSPoint(x: 416, y: 228), controlPoint1: NSPoint(x: 340, y: 228), controlPoint2: NSPoint(x: 380, y: 228))
NSColor(calibratedRed: 0.29, green: 0.42, blue: 0.36, alpha: 0.72).setStroke()
arrowPath.stroke()

let arrowHead = NSBezierPath()
arrowHead.move(to: NSPoint(x: 396, y: 248))
arrowHead.line(to: NSPoint(x: 424, y: 228))
arrowHead.line(to: NSPoint(x: 396, y: 208))
arrowHead.lineWidth = 8
arrowHead.lineCapStyle = .round
arrowHead.lineJoinStyle = .round
arrowHead.stroke()
NSGraphicsContext.restoreGraphicsState()

let titleStyle = NSMutableParagraphStyle()
titleStyle.alignment = .left

let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 34, weight: .semibold),
    .foregroundColor: NSColor(calibratedRed: 0.16, green: 0.21, blue: 0.19, alpha: 1),
    .paragraphStyle: titleStyle
]

let subtitleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 17, weight: .regular),
    .foregroundColor: NSColor(calibratedRed: 0.29, green: 0.35, blue: 0.33, alpha: 1),
    .paragraphStyle: titleStyle
]

let footerAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 12, weight: .medium),
    .foregroundColor: NSColor(calibratedRed: 0.38, green: 0.43, blue: 0.41, alpha: 1),
    .paragraphStyle: titleStyle
]

NSString(string: "Install Chau7").draw(in: NSRect(x: 58, y: 366, width: 360, height: 42), withAttributes: titleAttrs)
NSString(string: "Drag the app to Applications to install this pre-release build.").draw(
    in: NSRect(x: 58, y: 320, width: 560, height: 44),
    withAttributes: subtitleAttrs
)
NSString(string: "Legal notices are bundled inside Chau7.app.").draw(
    in: NSRect(x: 58, y: 42, width: 540, height: 20),
    withAttributes: footerAttrs
)

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiff)
else {
    fputs("Unable to encode background image\n", stderr)
    exit(1)
}

let fileExtension = outputURL.pathExtension.lowercased()
let imageData: Data?
switch fileExtension {
case "jpg", "jpeg":
    imageData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
default:
    imageData = bitmap.representation(using: .png, properties: [:])
}

guard let imageData else {
    fputs("Unable to encode output image data\n", stderr)
    exit(1)
}

do {
    try imageData.write(to: outputURL)
} catch {
    fputs("Failed to write background image: \(error)\n", stderr)
    exit(1)
}
