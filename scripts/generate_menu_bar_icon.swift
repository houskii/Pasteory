import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("usage: generate_menu_bar_icon.swift OUTPUT_1X_PNG OUTPUT_2X_PNG\n", stderr)
    exit(2)
}

private let pointSize: CGFloat = 18

private func pagePath(offsetX: CGFloat, offsetY: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: 3.1 + offsetX, y: 1.8 + offsetY))
    path.line(to: NSPoint(x: 3.1 + offsetX, y: 16.0 + offsetY))
    path.line(to: NSPoint(x: 9.0 + offsetX, y: 16.0 + offsetY))
    path.curve(
        to: NSPoint(x: 15.0 + offsetX, y: 11.9 + offsetY),
        controlPoint1: NSPoint(x: 12.8 + offsetX, y: 16.0 + offsetY),
        controlPoint2: NSPoint(x: 15.0 + offsetX, y: 14.1 + offsetY)
    )
    path.curve(
        to: NSPoint(x: 9.0 + offsetX, y: 7.8 + offsetY),
        controlPoint1: NSPoint(x: 15.0 + offsetX, y: 9.6 + offsetY),
        controlPoint2: NSPoint(x: 12.8 + offsetX, y: 7.8 + offsetY)
    )
    path.line(to: NSPoint(x: 6.1 + offsetX, y: 7.8 + offsetY))
    path.line(to: NSPoint(x: 6.1 + offsetX, y: 1.8 + offsetY))
    path.close()
    path.appendRoundedRect(
        NSRect(x: 6.4 + offsetX, y: 10.4 + offsetY, width: 4.5, height: 2.7),
        xRadius: 1.15,
        yRadius: 1.15
    )
    path.windingRule = .evenOdd
    return path
}

private func drawLayer(offsetX: CGFloat, offsetY: CGFloat, alpha: CGFloat) {
    NSColor.black.withAlphaComponent(alpha).setFill()
    pagePath(offsetX: offsetX, offsetY: offsetY).fill()
}

private func renderPNG(pixelSize: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "PasteoryMenuBarIcon", code: 1)
    }

    bitmap.size = NSSize(width: pointSize, height: pointSize)
    let previousContext = NSGraphicsContext.current
    NSGraphicsContext.current = context
    context.shouldAntialias = true

    NSColor.clear.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: pointSize, height: pointSize)).fill()
    drawLayer(offsetX: 1.2, offsetY: 0.6, alpha: 0.28)
    drawLayer(offsetX: 0.6, offsetY: 0.3, alpha: 0.56)
    drawLayer(offsetX: 0, offsetY: 0, alpha: 1)

    NSGraphicsContext.current = previousContext
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "PasteoryMenuBarIcon", code: 2)
    }
    return png
}

try renderPNG(pixelSize: 18).write(
    to: URL(fileURLWithPath: CommandLine.arguments[1]),
    options: .atomic
)
try renderPNG(pixelSize: 36).write(
    to: URL(fileURLWithPath: CommandLine.arguments[2]),
    options: .atomic
)
