import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("usage: generate_menu_bar_icon.swift OUTPUT_1X_PNG OUTPUT_2X_PNG\n", stderr)
    exit(2)
}

private struct BrandMask {
    let width: Int
    let height: Int
    let pixels: [Bool]
    let bounds: CGRect

    func contains(x: Int, y: Int) -> Bool {
        guard x >= 0, x < width, y >= 0, y < height else { return false }
        return pixels[y * width + x]
    }
}

private struct ProjectedLayer {
    let offsetX: CGFloat
    let offsetY: CGFloat
    let opacity: CGFloat
    let includesClamp: Bool
}

private let layers = [
    ProjectedLayer(offsetX: 90, offsetY: 42, opacity: 0.28, includesClamp: false),
    ProjectedLayer(offsetX: 45, offsetY: 21, opacity: 0.55, includesClamp: false),
    ProjectedLayer(offsetX: 0, offsetY: 0, opacity: 1, includesClamp: true)
]

private func loadBrandMask() throws -> BrandMask {
    let sourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("docs/brand/pasteory-app-icon.png")
    let data = try Data(contentsOf: sourceURL)
    guard let bitmap = NSBitmapImageRep(data: data) else {
        throw NSError(
            domain: "PasteoryMenuBarIcon",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "无法读取应用图标准稿"]
        )
    }

    let width = bitmap.pixelsWide
    let height = bitmap.pixelsHigh
    var candidates = [Bool](repeating: false, count: width * height)
    for y in 0..<height {
        let normalizedY = CGFloat(y) / CGFloat(height)
        for x in 0..<width {
            let normalizedX = CGFloat(x) / CGFloat(width)
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            let red = color.redComponent
            let green = color.greenComponent
            let blue = color.blueComponent
            let alpha = color.alphaComponent

            let inFrontP = (0.20...0.74).contains(normalizedX)
                && (0.15...0.90).contains(normalizedY)
            let inClamp = (0.30...0.57).contains(normalizedX)
                && (0.09...0.29).contains(normalizedY)
            let warmFront = red > 0.72
                && green > 0.62
                && blue > 0.48
                && red >= blue * 0.98
            let neutralClamp = red > 0.28
                && green > 0.24
                && blue > 0.20
                && red >= blue * 0.82
                && green >= blue * 0.72
            candidates[y * width + x] = alpha > 0.2
                && ((inFrontP && warmFront) || (inClamp && neutralClamp))
        }
    }

    // Keep only substantial connected areas. This retains the front P and its
    // clamp while discarding isolated bright texture pixels from the tile.
    var visited = [Bool](repeating: false, count: candidates.count)
    var retained = [Bool](repeating: false, count: candidates.count)
    let neighbors = [(-1, 0), (1, 0), (0, -1), (0, 1)]
    for index in candidates.indices where candidates[index] && !visited[index] {
        var queue = [index]
        var cursor = 0
        var component = [Int]()
        visited[index] = true
        while cursor < queue.count {
            let current = queue[cursor]
            cursor += 1
            component.append(current)
            let x = current % width
            let y = current / width
            for (dx, dy) in neighbors {
                let nextX = x + dx
                let nextY = y + dy
                guard nextX >= 0, nextX < width, nextY >= 0, nextY < height else { continue }
                let next = nextY * width + nextX
                guard candidates[next], !visited[next] else { continue }
                visited[next] = true
                queue.append(next)
            }
        }
        if component.count >= 500 {
            for value in component { retained[value] = true }
        }
    }

    // Recover the dark bevel at the edge without changing the large P counter
    // or the hole in the clipboard clamp.
    var expanded = retained
    let radius = 3
    for y in 0..<height {
        for x in 0..<width where retained[y * width + x] {
            for dy in -radius...radius {
                for dx in -radius...radius where dx * dx + dy * dy <= radius * radius {
                    let nextX = x + dx
                    let nextY = y + dy
                    guard nextX >= 0, nextX < width, nextY >= 0, nextY < height else { continue }
                    expanded[nextY * width + nextX] = true
                }
            }
        }
    }

    var minX = width
    var minY = height
    var maxX = -1
    var maxY = -1
    for y in 0..<height {
        for x in 0..<width where expanded[y * width + x] {
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }
    }
    guard maxX >= minX, maxY >= minY else {
        throw NSError(
            domain: "PasteoryMenuBarIcon",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "应用图标准稿中没有可提取的 P 轮廓"]
        )
    }
    return BrandMask(
        width: width,
        height: height,
        pixels: expanded,
        bounds: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    )
}

private func renderPNG(pixelSize: Int, mask: BrandMask) throws -> Data {
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
    ) else {
        throw NSError(domain: "PasteoryMenuBarIcon", code: 3)
    }

    let farthestX = layers.map(\.offsetX).max() ?? 0
    let farthestY = layers.map(\.offsetY).max() ?? 0
    let projectedWidth = mask.bounds.width + farthestX
    let projectedHeight = mask.bounds.height + farthestY
    let pointScale = min(14.5 / projectedWidth, 15.5 / projectedHeight)
    let drawnWidth = projectedWidth * pointScale
    let drawnHeight = projectedHeight * pointScale
    let originX = (18 - drawnWidth) / 2
    let originY = (18 - drawnHeight) / 2
    let pixelScale = CGFloat(pixelSize) / 18
    let samplesPerAxis = 5
    // The P body starts below the raised clipboard clamp in the approved icon.
    // Back layers use that body silhouette only, so the clamp is not repeated.
    let pBodyTop = Int((CGFloat(mask.height) * 0.16).rounded())

    for outputY in 0..<pixelSize {
        for outputX in 0..<pixelSize {
            var accumulatedAlpha: CGFloat = 0
            for sampleY in 0..<samplesPerAxis {
                for sampleX in 0..<samplesPerAxis {
                    let pointX = (CGFloat(outputX) + (CGFloat(sampleX) + 0.5) / CGFloat(samplesPerAxis)) / pixelScale
                    let pointY = (CGFloat(outputY) + (CGFloat(sampleY) + 0.5) / CGFloat(samplesPerAxis)) / pixelScale
                    let projectedX = (pointX - originX) / pointScale + mask.bounds.minX
                    let projectedY = (pointY - originY) / pointScale + mask.bounds.minY
                    var sampleAlpha: CGFloat = 0
                    for layer in layers {
                        let sourceX = Int((projectedX - layer.offsetX).rounded())
                        let sourceY = Int((projectedY - layer.offsetY).rounded())
                        guard layer.includesClamp || sourceY >= pBodyTop else { continue }
                        guard mask.contains(x: sourceX, y: sourceY) else { continue }
                        sampleAlpha = 1 - (1 - sampleAlpha) * (1 - layer.opacity)
                    }
                    accumulatedAlpha += sampleAlpha
                }
            }
            let alpha = accumulatedAlpha / CGFloat(samplesPerAxis * samplesPerAxis)
            bitmap.setColor(
                NSColor(deviceRed: 0, green: 0, blue: 0, alpha: alpha),
                atX: outputX,
                y: outputY
            )
        }
    }

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "PasteoryMenuBarIcon", code: 4)
    }
    return png
}

private let mask = try loadBrandMask()
print(
    "brand_mask=\(Int(mask.bounds.minX)),\(Int(mask.bounds.minY)) "
        + "\(Int(mask.bounds.width))x\(Int(mask.bounds.height))"
)
try renderPNG(pixelSize: 18, mask: mask).write(
    to: URL(fileURLWithPath: CommandLine.arguments[1]),
    options: .atomic
)
try renderPNG(pixelSize: 36, mask: mask).write(
    to: URL(fileURLWithPath: CommandLine.arguments[2]),
    options: .atomic
)
