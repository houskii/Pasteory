import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: generate_icon.swift OUTPUT_PNG\n", stderr)
    exit(2)
}

let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()

let background = NSBezierPath(roundedRect: NSRect(x: 44, y: 44, width: 936, height: 936), xRadius: 220, yRadius: 220)
let gradient = NSGradient(colors: [NSColor(calibratedRed: 0.48, green: 0.23, blue: 0.93, alpha: 1), NSColor(calibratedRed: 0.30, green: 0.12, blue: 0.72, alpha: 1)])!
gradient.draw(in: background, angle: -55)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.20); shadow.shadowBlurRadius = 28; shadow.shadowOffset = NSSize(width: 0, height: -14); shadow.set()
let backCard = NSBezierPath(roundedRect: NSRect(x: 270, y: 235, width: 545, height: 560), xRadius: 78, yRadius: 78)
NSColor.white.withAlphaComponent(0.52).setFill(); backCard.fill()
NSGraphicsContext.restoreGraphicsState()

let frontCard = NSBezierPath(roundedRect: NSRect(x: 205, y: 175, width: 570, height: 590), xRadius: 82, yRadius: 82)
NSColor.white.withAlphaComponent(0.96).setFill(); frontCard.fill()

let clip = NSBezierPath(roundedRect: NSRect(x: 365, y: 680, width: 250, height: 105), xRadius: 45, yRadius: 45)
NSColor(calibratedRed: 0.42, green: 0.18, blue: 0.86, alpha: 1).setFill(); clip.fill()
let clipInset = NSBezierPath(roundedRect: NSRect(x: 420, y: 716, width: 140, height: 34), xRadius: 16, yRadius: 16)
NSColor.white.withAlphaComponent(0.92).setFill(); clipInset.fill()

for index in 0..<3 {
    let line = NSBezierPath(roundedRect: NSRect(x: 310, y: 535 - CGFloat(index * 105), width: index == 2 ? 285 : 365, height: 34), xRadius: 17, yRadius: 17)
    NSColor(calibratedRed: 0.48, green: 0.23, blue: 0.93, alpha: index == 0 ? 0.90 : 0.52).setFill(); line.fill()
}

image.unlockFocus()
guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("failed to render icon\n", stderr); exit(1)
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
