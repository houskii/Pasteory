import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("usage: verify_menu_bar_icon.swift ICON_1X ICON_2X\n", stderr)
    exit(2)
}

struct Metrics {
    let pixels: Int
    let visiblePixels: Int
    let width: Int
    let height: Int

    var widthRatio: Double { Double(width) / Double(pixels) }
    var heightRatio: Double { Double(height) / Double(pixels) }
}

func metrics(path: String, expectedPixels: Int) throws -> Metrics {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard let bitmap = NSBitmapImageRep(data: data),
          bitmap.pixelsWide == expectedPixels,
          bitmap.pixelsHigh == expectedPixels else {
        throw NSError(
            domain: "PasteoryMenuBarIconVerification",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "菜单栏图标尺寸错误：\(path)"]
        )
    }

    var minX = expectedPixels
    var minY = expectedPixels
    var maxX = -1
    var maxY = -1
    var visiblePixels = 0
    for y in 0..<expectedPixels {
        for x in 0..<expectedPixels {
            guard let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.02 else { continue }
            visiblePixels += 1
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }
    }
    guard visiblePixels > 0 else {
        throw NSError(
            domain: "PasteoryMenuBarIconVerification",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "菜单栏图标没有可见内容：\(path)"]
        )
    }
    return Metrics(
        pixels: expectedPixels,
        visiblePixels: visiblePixels,
        width: maxX - minX + 1,
        height: maxY - minY + 1
    )
}

let oneX = try metrics(path: CommandLine.arguments[1], expectedPixels: 18)
let twoX = try metrics(path: CommandLine.arguments[2], expectedPixels: 36)
let ratiosAreReasonable = (0.65...0.95).contains(oneX.widthRatio)
    && (0.75...1.0).contains(oneX.heightRatio)
    && (0.65...0.95).contains(twoX.widthRatio)
    && (0.75...1.0).contains(twoX.heightRatio)
let representationsMatch = abs(oneX.widthRatio - twoX.widthRatio) <= 0.08
    && abs(oneX.heightRatio - twoX.heightRatio) <= 0.08
let visiblePixelScale = Double(twoX.visiblePixels) / Double(oneX.visiblePixels)
guard ratiosAreReasonable, representationsMatch, (3.0...5.0).contains(visiblePixelScale) else {
    throw NSError(
        domain: "PasteoryMenuBarIconVerification",
        code: 3,
        userInfo: [NSLocalizedDescriptionKey: "1×／2× 菜单栏图标的可见范围不一致"]
    )
}

print(
    "menu_bar_icon=ok "
        + "1x=\(oneX.width)x\(oneX.height) "
        + "2x=\(twoX.width)x\(twoX.height) "
        + "visible_scale=\(String(format: "%.2f", visiblePixelScale))"
)
