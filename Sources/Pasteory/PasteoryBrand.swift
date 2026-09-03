import AppKit

@MainActor
enum PasteoryBrand {
    static let name = "Pasteory"
    static let tagline = "Pasteory learns from what you copied."
    static let taglineChinese = "从复制过的内容里，学会你做事的习惯。"

    static func appIconImage() -> NSImage {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSApp.applicationIconImage
    }

    static func menuBarImage() -> NSImage {
        if let packagedImage = packagedMenuBarImage() {
            return packagedImage
        }

        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            drawPage(offsetX: 1.3, offsetY: 0.7, alpha: 0.22)
            drawPage(offsetX: 0.65, offsetY: 0.35, alpha: 0.48)
            drawPage(offsetX: 0, offsetY: 0, alpha: 1)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = name
        return image
    }

    private static func packagedMenuBarImage() -> NSImage? {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        var loadedRepresentation = false
        for resourceName in ["MenuBarIcon", "MenuBarIcon@2x"] {
            var candidates = [URL]()
            if let packaged = Bundle.main.url(forResource: resourceName, withExtension: "png") {
                candidates.append(packaged)
            }
#if DEBUG
            candidates.append(
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                    .appendingPathComponent("docs/brand/\(resourceName == "MenuBarIcon" ? "pasteory-menu-bar-icon" : "pasteory-menu-bar-icon@2x").png")
            )
#endif
            guard let representation = candidates.lazy.compactMap({ url -> NSBitmapImageRep? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return NSBitmapImageRep(data: data)
            }).first else { continue }
            representation.size = NSSize(width: 18, height: 18)
            image.addRepresentation(representation)
            loadedRepresentation = true
        }
        guard loadedRepresentation else { return nil }
        image.isTemplate = true
        image.accessibilityDescription = name
        return image
    }

    private static func drawPage(offsetX: CGFloat, offsetY: CGFloat, alpha: CGFloat) {
        NSColor.black.withAlphaComponent(alpha).setFill()
        pagePath(offsetX: offsetX, offsetY: offsetY).fill()
    }

    private static func pagePath(offsetX: CGFloat, offsetY: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 3.4 + offsetX, y: 2.0 + offsetY))
        path.line(to: NSPoint(x: 3.4 + offsetX, y: 15.7 + offsetY))
        path.line(to: NSPoint(x: 9.1 + offsetX, y: 15.7 + offsetY))
        path.curve(
            to: NSPoint(x: 14.8 + offsetX, y: 11.8 + offsetY),
            controlPoint1: NSPoint(x: 12.8 + offsetX, y: 15.7 + offsetY),
            controlPoint2: NSPoint(x: 14.8 + offsetX, y: 14.0 + offsetY)
        )
        path.curve(
            to: NSPoint(x: 9.1 + offsetX, y: 7.8 + offsetY),
            controlPoint1: NSPoint(x: 14.8 + offsetX, y: 9.5 + offsetY),
            controlPoint2: NSPoint(x: 12.8 + offsetX, y: 7.8 + offsetY)
        )
        path.line(to: NSPoint(x: 6.3 + offsetX, y: 7.8 + offsetY))
        path.line(to: NSPoint(x: 6.3 + offsetX, y: 2.0 + offsetY))
        path.close()
        path.appendRoundedRect(
            NSRect(x: 6.5 + offsetX, y: 10.4 + offsetY, width: 4.4, height: 2.6),
            xRadius: 1.1,
            yRadius: 1.1
        )
        path.windingRule = .evenOdd
        return path
    }
}
