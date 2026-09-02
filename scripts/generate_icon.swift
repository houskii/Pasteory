import AppKit
import Foundation

guard (2...3).contains(CommandLine.arguments.count) else {
    fputs("usage: generate_icon.swift OUTPUT_PNG [MENU_BAR_PREVIEW_PNG]\n", stderr)
    exit(2)
}

private func pasteoryPPath() -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: 269, y: 145))
    path.line(to: NSPoint(x: 339, y: 145))
    path.curve(to: NSPoint(x: 399, y: 205), controlPoint1: NSPoint(x: 375, y: 145), controlPoint2: NSPoint(x: 399, y: 169))
    path.line(to: NSPoint(x: 399, y: 360))
    path.curve(to: NSPoint(x: 459, y: 420), controlPoint1: NSPoint(x: 399, y: 396), controlPoint2: NSPoint(x: 423, y: 420))
    path.line(to: NSPoint(x: 549, y: 420))
    path.curve(to: NSPoint(x: 769, y: 617.5), controlPoint1: NSPoint(x: 687, y: 420), controlPoint2: NSPoint(x: 769, y: 507))
    path.curve(to: NSPoint(x: 549, y: 815), controlPoint1: NSPoint(x: 769, y: 728), controlPoint2: NSPoint(x: 687, y: 815))
    path.line(to: NSPoint(x: 269, y: 815))
    path.curve(to: NSPoint(x: 209, y: 755), controlPoint1: NSPoint(x: 233, y: 815), controlPoint2: NSPoint(x: 209, y: 791))
    path.line(to: NSPoint(x: 209, y: 205))
    path.curve(to: NSPoint(x: 269, y: 145), controlPoint1: NSPoint(x: 209, y: 169), controlPoint2: NSPoint(x: 233, y: 145))
    path.close()

    let counter = NSBezierPath()
    counter.move(to: NSPoint(x: 461, y: 557))
    counter.line(to: NSPoint(x: 461, y: 678))
    counter.curve(to: NSPoint(x: 498, y: 715), controlPoint1: NSPoint(x: 461, y: 700), controlPoint2: NSPoint(x: 476, y: 715))
    counter.line(to: NSPoint(x: 555, y: 715))
    counter.curve(to: NSPoint(x: 660, y: 636), controlPoint1: NSPoint(x: 620, y: 715), controlPoint2: NSPoint(x: 660, y: 683))
    counter.curve(to: NSPoint(x: 555, y: 520), controlPoint1: NSPoint(x: 660, y: 568), controlPoint2: NSPoint(x: 620, y: 520))
    counter.line(to: NSPoint(x: 498, y: 520))
    counter.curve(to: NSPoint(x: 461, y: 557), controlPoint1: NSPoint(x: 476, y: 520), controlPoint2: NSPoint(x: 461, y: 535))
    counter.close()
    path.append(counter)
    path.windingRule = .evenOdd
    return path
}

private func translatedPPath(x: CGFloat, y: CGFloat) -> NSBezierPath {
    let path = pasteoryPPath().copy() as! NSBezierPath
    let transform = AffineTransform(translationByX: x, byY: y)
    path.transform(using: transform)
    return path
}

private func drawP(
    _ path: NSBezierPath,
    colors: [NSColor],
    shadowOpacity: CGFloat,
    shadowOffset: NSSize
) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(shadowOpacity)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = shadowOffset
    shadow.set()
    colors[0].setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: colors)!.draw(in: path, angle: -58)
    NSColor.white.withAlphaComponent(0.30).setStroke()
    path.lineWidth = 2
    path.stroke()
}

private func clipboardClampPath() -> NSBezierPath {
    let clamp = NSBezierPath(roundedRect: NSRect(x: 349, y: 770, width: 252, height: 96), xRadius: 28, yRadius: 28)
    let loop = NSBezierPath(ovalIn: NSRect(x: 430, y: 824, width: 90, height: 94))
    loop.appendOval(in: NSRect(x: 456, y: 852, width: 38, height: 38))
    loop.windingRule = .evenOdd
    clamp.append(loop)
    clamp.windingRule = .evenOdd
    return clamp
}

private func renderAppIcon() -> NSImage {
    let approvedIconURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("docs/brand/pasteory-app-icon.png")
    if let approvedIcon = NSImage(contentsOf: approvedIconURL) {
        return approvedIcon
    }

    let image = NSImage(size: NSSize(width: 1024, height: 1024))
    image.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high

    NSColor.clear.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1024, height: 1024)).fill()

    let tile = NSBezierPath(roundedRect: NSRect(x: 52, y: 52, width: 920, height: 920), xRadius: 210, yRadius: 210)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 34
    shadow.shadowOffset = NSSize(width: 0, height: -18)
    shadow.set()
    NSColor(calibratedRed: 0.06, green: 0.08, blue: 0.25, alpha: 1).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.03, green: 0.34, blue: 0.98, alpha: 1),
        NSColor(calibratedRed: 0.15, green: 0.13, blue: 0.62, alpha: 1),
        NSColor(calibratedRed: 0.63, green: 0.19, blue: 0.92, alpha: 1)
    ])!
    gradient.draw(in: tile, angle: -50)

    NSColor.white.withAlphaComponent(0.14).setStroke()
    tile.lineWidth = 3
    tile.stroke()

    // Every layer uses the exact same path. Only the equal translation changes.
    drawP(
        translatedPPath(x: 56, y: 36),
        colors: [
            NSColor(calibratedRed: 0.20, green: 0.40, blue: 1.00, alpha: 1),
            NSColor(calibratedRed: 0.42, green: 0.55, blue: 1.00, alpha: 1)
        ],
        shadowOpacity: 0.20,
        shadowOffset: NSSize(width: 0, height: -10)
    )
    drawP(
        translatedPPath(x: 28, y: 18),
        colors: [
            NSColor(calibratedRed: 0.47, green: 0.36, blue: 0.91, alpha: 1),
            NSColor(calibratedRed: 0.75, green: 0.64, blue: 1.00, alpha: 1)
        ],
        shadowOpacity: 0.17,
        shadowOffset: NSSize(width: 0, height: -9)
    )
    drawP(
        pasteoryPPath(),
        colors: [
            NSColor(calibratedRed: 0.93, green: 0.90, blue: 0.85, alpha: 1),
            NSColor(calibratedRed: 1.00, green: 0.99, blue: 0.96, alpha: 1)
        ],
        shadowOpacity: 0.28,
        shadowOffset: NSSize(width: 0, height: -13)
    )

    let clamp = clipboardClampPath()
    NSGraphicsContext.saveGraphicsState()
    let clampShadow = NSShadow()
    clampShadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    clampShadow.shadowBlurRadius = 14
    clampShadow.shadowOffset = NSSize(width: 0, height: -7)
    clampShadow.set()
    NSColor(calibratedWhite: 0.45, alpha: 1).setFill()
    clamp.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [
        NSColor(calibratedWhite: 0.97, alpha: 1),
        NSColor(calibratedWhite: 0.55, alpha: 1),
        NSColor(calibratedWhite: 0.84, alpha: 1)
    ])!.draw(in: clamp, angle: -82)
    NSColor.white.withAlphaComponent(0.68).setStroke()
    clamp.lineWidth = 2.5
    clamp.stroke()

    image.unlockFocus()
    return image
}

private func menuPPath(offsetX: CGFloat = 0, offsetY: CGFloat = 0) -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: 3.4 + offsetX, y: 2.0 + offsetY))
    path.line(to: NSPoint(x: 3.4 + offsetX, y: 15.7 + offsetY))
    path.line(to: NSPoint(x: 9.1 + offsetX, y: 15.7 + offsetY))
    path.curve(to: NSPoint(x: 14.8 + offsetX, y: 11.8 + offsetY), controlPoint1: NSPoint(x: 12.8 + offsetX, y: 15.7 + offsetY), controlPoint2: NSPoint(x: 14.8 + offsetX, y: 14.0 + offsetY))
    path.curve(to: NSPoint(x: 9.1 + offsetX, y: 7.8 + offsetY), controlPoint1: NSPoint(x: 14.8 + offsetX, y: 9.5 + offsetY), controlPoint2: NSPoint(x: 12.8 + offsetX, y: 7.8 + offsetY))
    path.line(to: NSPoint(x: 6.3 + offsetX, y: 7.8 + offsetY))
    path.line(to: NSPoint(x: 6.3 + offsetX, y: 2.0 + offsetY))
    path.close()
    path.appendRoundedRect(NSRect(x: 6.5 + offsetX, y: 10.4 + offsetY, width: 4.4, height: 2.6), xRadius: 1.1, yRadius: 1.1)
    path.windingRule = .evenOdd
    return path
}

private func drawMenuMark(in rect: NSRect, color: NSColor) {
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: rect.minX, yBy: rect.minY)
    transform.scaleX(by: rect.width / 18, yBy: rect.height / 18)
    transform.concat()

    color.withAlphaComponent(0.22).setFill()
    menuPPath(offsetX: 1.3, offsetY: 0.7).fill()
    color.withAlphaComponent(0.48).setFill()
    menuPPath(offsetX: 0.65, offsetY: 0.35).fill()
    color.setFill()
    menuPPath().fill()
    NSGraphicsContext.restoreGraphicsState()
}

private func renderMenuBarPreview() -> NSImage {
    let preview = NSImage(size: NSSize(width: 640, height: 240))
    preview.lockFocus()
    NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 120, width: 640, height: 120)).fill()
    NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 640, height: 120)).fill()

    drawMenuMark(in: NSRect(x: 82, y: 171, width: 18, height: 18), color: .black)
    drawMenuMark(in: NSRect(x: 142, y: 154, width: 52, height: 52), color: .black)
    drawMenuMark(in: NSRect(x: 82, y: 51, width: 18, height: 18), color: .white)
    drawMenuMark(in: NSRect(x: 142, y: 34, width: 52, height: 52), color: .white)

    let attributesLight: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18, weight: .medium), .foregroundColor: NSColor.black]
    let attributesDark: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18, weight: .medium), .foregroundColor: NSColor.white]
    NSAttributedString(string: "Pasteory · 菜单栏浅色模式", attributes: attributesLight).draw(at: NSPoint(x: 230, y: 171))
    NSAttributedString(string: "Pasteory · 菜单栏深色模式", attributes: attributesDark).draw(at: NSPoint(x: 230, y: 51))
    preview.unlockFocus()
    return preview
}

private func writePNG(_ image: NSImage, to path: String) throws {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "PasteoryIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "failed to render icon"])
    }
    try png.write(to: URL(fileURLWithPath: path), options: .atomic)
}

try writePNG(renderAppIcon(), to: CommandLine.arguments[1])
if CommandLine.arguments.count == 3 {
    try writePNG(renderMenuBarPreview(), to: CommandLine.arguments[2])
}
