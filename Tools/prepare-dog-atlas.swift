#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct RGBAImage {
    let width: Int
    let height: Int
    var bytes: [UInt8]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.bytes = Array(repeating: 0, count: width * height * 4)
    }

    init(cgImage: CGImage, width: Int, height: Int) {
        self.width = width
        self.height = height
        self.bytes = Array(repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    func makeCGImage() -> CGImage {
        bytes.withUnsafeBytes { raw in
            let provider = CGDataProvider(data: Data(raw) as CFData)!
            return CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            )!
        }
    }

    mutating func clearPixel(_ index: Int) {
        let offset = index * 4
        bytes[offset] = 0
        bytes[offset + 1] = 0
        bytes[offset + 2] = 0
        bytes[offset + 3] = 0
    }

    func alpha(at index: Int) -> UInt8 { bytes[index * 4 + 3] }
}

struct Bounds {
    var minX: Int
    var minY: Int
    var maxX: Int
    var maxY: Int

    var width: Int { maxX - minX + 1 }
    var height: Int { maxY - minY + 1 }
}

let columns = 8
let rows = 11
let cellWidth = 192
let cellHeight = 208
let atlasWidth = columns * cellWidth
let atlasHeight = rows * cellHeight
let usedPerRow = [6, 8, 8, 4, 5, 8, 6, 6, 6, 8, 8]

func isUsed(row: Int, column: Int) -> Bool {
    column < usedPerRow[row]
}

func loadCGImage(_ path: String) -> CGImage {
    let url = URL(fileURLWithPath: path) as CFURL
    let source = CGImageSourceCreateWithURL(url, nil)!
    return CGImageSourceCreateImageAtIndex(source, 0, nil)!
}

func writePNG(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    let destination = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination), "Could not write \(path)")
}

func cleanedCell(from source: CGImage, row: Int, column: Int) -> RGBAImage {
    let x0 = Int((Double(column) * Double(source.width) / Double(columns)).rounded())
    let x1 = Int((Double(column + 1) * Double(source.width) / Double(columns)).rounded())
    let y0 = Int((Double(row) * Double(source.height) / Double(rows)).rounded())
    let y1 = Int((Double(row + 1) * Double(source.height) / Double(rows)).rounded())
    let crop = source.cropping(to: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))!
    var image = RGBAImage(cgImage: crop, width: cellWidth, height: cellHeight)

    // Remove generation guide residue and low-alpha noise. The character blue
    // has a substantial red channel; the electric-blue/cyan residue does not.
    for y in 0..<cellHeight {
        for x in 0..<cellWidth {
            let index = y * cellWidth + x
            let offset = index * 4
            let r = Int(image.bytes[offset])
            let g = Int(image.bytes[offset + 1])
            let b = Int(image.bytes[offset + 2])
            let a = Int(image.bytes[offset + 3])
            // The blue guide crosses the bottom of each source cell. A blanket
            // bottom crop erased paws; remove guide colours, not the whole strip.
            let edgeGuide = x < 3 || x > cellWidth - 4 || y < 2
            let electricBlue = a > 0 && r < 34 && b > 105 && (b - r > 95 || g > 82)
            if a < 18 || edgeGuide || electricBlue {
                image.clearPixel(index)
            }
        }
    }

    // Keep meaningful connected artwork while dropping isolated speckles.
    let pixelCount = cellWidth * cellHeight
    var visited = Array(repeating: false, count: pixelCount)
    var keep = Array(repeating: false, count: pixelCount)
    let neighbors = [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)]

    for start in 0..<pixelCount where !visited[start] && image.alpha(at: start) >= 18 {
        visited[start] = true
        var queue = [start]
        var cursor = 0
        while cursor < queue.count {
            let current = queue[cursor]
            cursor += 1
            let x = current % cellWidth
            let y = current / cellWidth
            for (dx, dy) in neighbors {
                let nx = x + dx
                let ny = y + dy
                guard nx >= 0, nx < cellWidth, ny >= 0, ny < cellHeight else { continue }
                let next = ny * cellWidth + nx
                if !visited[next] && image.alpha(at: next) >= 18 {
                    visited[next] = true
                    queue.append(next)
                }
            }
        }
        if queue.count >= 42 {
            for index in queue { keep[index] = true }
        }
    }

    for index in 0..<pixelCount where !keep[index] {
        image.clearPixel(index)
    }
    return image
}

func contentBounds(_ image: RGBAImage) -> Bounds? {
    var minX = image.width
    var minY = image.height
    var maxX = -1
    var maxY = -1
    for y in 0..<image.height {
        for x in 0..<image.width {
            if image.alpha(at: y * image.width + x) >= 18 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
    }
    guard maxX >= minX, maxY >= minY else { return nil }
    return Bounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
}

func drawTopLeft(_ image: CGImage, in rect: CGRect, context: CGContext, canvasHeight: Int) {
    let quartzRect = CGRect(
        x: rect.origin.x,
        y: CGFloat(canvasHeight) - rect.origin.y - rect.height,
        width: rect.width,
        height: rect.height
    )
    context.draw(image, in: quartzRect)
}

func makeContext(width: Int, height: Int) -> (CGContext, UnsafeMutableRawPointer) {
    let pointer = UnsafeMutableRawPointer.allocate(byteCount: width * height * 4, alignment: 64)
    pointer.initializeMemory(as: UInt8.self, repeating: 0, count: width * height * 4)
    let context = CGContext(
        data: pointer,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.interpolationQuality = .high
    return (context, pointer)
}

func blitScaled(
    source: RGBAImage,
    sourceBounds: Bounds,
    destination: inout RGBAImage,
    destinationX: Int,
    destinationY: Int,
    destinationWidth: Int,
    destinationHeight: Int
) {
    guard destinationWidth > 0, destinationHeight > 0 else { return }
    for dy in 0..<destinationHeight {
        let sourceY = Double(sourceBounds.minY) + (Double(dy) + 0.5) * Double(sourceBounds.height) / Double(destinationHeight) - 0.5
        let y0 = max(sourceBounds.minY, min(sourceBounds.maxY, Int(floor(sourceY))))
        let y1 = max(sourceBounds.minY, min(sourceBounds.maxY, y0 + 1))
        let fy = sourceY - floor(sourceY)
        for dx in 0..<destinationWidth {
            let sourceX = Double(sourceBounds.minX) + (Double(dx) + 0.5) * Double(sourceBounds.width) / Double(destinationWidth) - 0.5
            let x0 = max(sourceBounds.minX, min(sourceBounds.maxX, Int(floor(sourceX))))
            let x1 = max(sourceBounds.minX, min(sourceBounds.maxX, x0 + 1))
            let fx = sourceX - floor(sourceX)
            let targetX = destinationX + dx
            let targetY = destinationY + dy
            guard targetX >= 0, targetX < destination.width, targetY >= 0, targetY < destination.height else { continue }
            let targetOffset = (targetY * destination.width + targetX) * 4
            let offsets = [
                (y0 * source.width + x0) * 4,
                (y0 * source.width + x1) * 4,
                (y1 * source.width + x0) * 4,
                (y1 * source.width + x1) * 4
            ]
            for channel in 0..<4 {
                let top = Double(source.bytes[offsets[0] + channel]) * (1 - fx) + Double(source.bytes[offsets[1] + channel]) * fx
                let bottom = Double(source.bytes[offsets[2] + channel]) * (1 - fx) + Double(source.bytes[offsets[3] + channel]) * fx
                destination.bytes[targetOffset + channel] = UInt8(max(0, min(255, Int((top * (1 - fy) + bottom * fy).rounded()))))
            }
        }
    }
}

func makePreview(atlas: CGImage, output: String) {
    let left = 220
    let top = 58
    let footer = 22
    let width = left + atlasWidth
    let height = top + atlasHeight + footer
    let (context, pointer) = makeContext(width: width, height: height)
    defer { pointer.deallocate() }

    context.setFillColor(NSColor(calibratedRed: 0.97, green: 0.94, blue: 0.88, alpha: 1).cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    drawTopLeft(atlas, in: CGRect(x: left, y: top, width: atlasWidth, height: atlasHeight), context: context, canvasHeight: height)

    let labels = [
        "1  Idle (6)", "2  Walk right (8)", "3  Walk left (8)", "4  Wave (4)",
        "5  Jump (5)", "6  Gentle oops (8)", "7  Waiting (6)", "8  Laptop (6)",
        "9  Celebration (6)", "10  Gaze views 1–8", "11  Gaze views 9–16"
    ]

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    let titleAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 24, weight: .semibold),
        .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 1)
    ]
    let rowAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 16, weight: .medium),
        .foregroundColor: NSColor(calibratedWhite: 0.20, alpha: 1)
    ]
    let frameAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
        .foregroundColor: NSColor(calibratedWhite: 0.28, alpha: 1)
    ]
    ("Dog companion sprite atlas — review sheet" as NSString).draw(at: NSPoint(x: 18, y: height - 39), withAttributes: titleAttributes)
    for row in 0..<rows {
        let topY = top + row * cellHeight
        let appKitY = height - topY - cellHeight / 2 - 8
        (labels[row] as NSString).draw(at: NSPoint(x: 16, y: appKitY), withAttributes: rowAttributes)

        for column in 0..<columns {
            let x = left + column * cellWidth
            let yTop = top + row * cellHeight
            context.setStrokeColor(NSColor(calibratedWhite: 0.72, alpha: 0.75).cgColor)
            context.setLineWidth(1)
            context.stroke(CGRect(x: x, y: height - yTop - cellHeight, width: cellWidth, height: cellHeight))
            let label: String
            label = row >= 9 ? "V\((row - 9) * 8 + column + 1)" :
                (isUsed(row: row, column: column) ? "F\(column + 1)" : "unused")
            (label as NSString).draw(at: NSPoint(x: x + 7, y: height - yTop - 18), withAttributes: frameAttributes)
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    writePNG(context.makeImage()!, to: output)
}

guard CommandLine.arguments.count == 4 else {
    fputs("usage: prepare-dog-atlas.swift SOURCE FINAL_ATLAS PREVIEW\n", stderr)
    exit(2)
}

let sourcePath = CommandLine.arguments[1]
let atlasPath = CommandLine.arguments[2]
let previewPath = CommandLine.arguments[3]
let source = loadCGImage(sourcePath)

var cells: [[RGBAImage?]] = Array(repeating: Array(repeating: nil, count: columns), count: rows)
var bounds: [[Bounds?]] = Array(repeating: Array(repeating: nil, count: columns), count: rows)
var maxContentWidth = 1
var maxContentHeight = 1

for row in 0..<rows {
    for column in 0..<columns where isUsed(row: row, column: column) {
        let cell = cleanedCell(from: source, row: row, column: column)
        let box = contentBounds(cell)
        cells[row][column] = cell
        bounds[row][column] = box
        if let box {
            maxContentWidth = max(maxContentWidth, box.width)
            maxContentHeight = max(maxContentHeight, box.height)
        }
    }
}

let allowedWidth = 170.0
let allowedHeight = 170.0
let globalScale = min(allowedWidth / Double(maxContentWidth), allowedHeight / Double(maxContentHeight))
var atlasImage = RGBAImage(width: atlasWidth, height: atlasHeight)

func normalizedCell(source: RGBAImage, bounds: Bounds) -> RGBAImage {
    var result = RGBAImage(width: cellWidth, height: cellHeight)
    let drawWidth = max(1, Int((Double(bounds.width) * globalScale).rounded()))
    let drawHeight = max(1, Int((Double(bounds.height) * globalScale).rounded()))
    let x = (cellWidth - drawWidth) / 2
    let y = 178 - drawHeight
    blitScaled(
        source: source,
        sourceBounds: bounds,
        destination: &result,
        destinationX: x,
        destinationY: y,
        destinationWidth: drawWidth,
        destinationHeight: drawHeight
    )
    return result
}

for row in 0..<rows {
    for column in 0..<columns where isUsed(row: row, column: column) {
        guard let cell = cells[row][column], let box = bounds[row][column] else { continue }
        let normalized = normalizedCell(source: cell, bounds: box)
        let destinationX = column * cellWidth
        let destinationY = row * cellHeight
        for y in 0..<cellHeight {
            let sourceOffset = y * cellWidth * 4
            let destinationOffset = ((destinationY + y) * atlasWidth + destinationX) * 4
            atlasImage.bytes[destinationOffset..<(destinationOffset + cellWidth * 4)] = normalized.bytes[sourceOffset..<(sourceOffset + cellWidth * 4)]
        }
    }
}

let atlas = atlasImage.makeCGImage()
writePNG(atlas, to: atlasPath)
makePreview(atlas: atlas, output: previewPath)

var validationErrors: [String] = []
var populatedCells = 0
var transparentCells = 0
var observedMinX = cellWidth
var observedMaxX = -1
var observedMinY = cellHeight
var observedMaxY = -1
for row in 0..<rows {
    for column in 0..<columns {
        var count = 0
        var box = Bounds(minX: cellWidth, minY: cellHeight, maxX: -1, maxY: -1)
        for y in 0..<cellHeight {
            for x in 0..<cellWidth {
                let atlasX = column * cellWidth + x
                let atlasY = row * cellHeight + y
                let alpha = atlasImage.bytes[(atlasY * atlasWidth + atlasX) * 4 + 3]
                if alpha > 0 {
                    count += 1
                    box.minX = min(box.minX, x)
                    box.minY = min(box.minY, y)
                    box.maxX = max(box.maxX, x)
                    box.maxY = max(box.maxY, y)
                }
            }
        }
        if isUsed(row: row, column: column) {
            populatedCells += 1
            if count == 0 {
                validationErrors.append("missing frame r\(row + 1)c\(column + 1)")
            } else {
                observedMinX = min(observedMinX, box.minX)
                observedMaxX = max(observedMaxX, box.maxX)
                observedMinY = min(observedMinY, box.minY)
                observedMaxY = max(observedMaxY, box.maxY)
                if box.minX < 9 || box.maxX > 182 || box.minY < 8 || box.maxY > 177 {
                    validationErrors.append("content bounds outside safe area r\(row + 1)c\(column + 1): \(box.minX),\(box.minY)-\(box.maxX),\(box.maxY)")
                }
            }
        } else {
            transparentCells += 1
            if count != 0 {
                validationErrors.append("unused cell is not transparent r\(row + 1)c\(column + 1)")
            }
        }
    }
}

if !validationErrors.isEmpty {
    for error in validationErrors { fputs("QA ERROR: \(error)\n", stderr) }
    exit(1)
}

print("source=\(source.width)x\(source.height)")
print("atlas=\(atlas.width)x\(atlas.height)")
print(String(format: "uniformScale=%.4f maxSourceBounds=%dx%d", globalScale, maxContentWidth, maxContentHeight))
print("usedFrames=\(populatedCells) unusedFrames=\(transparentCells)")
print("contentBoundsAcrossCells=x\(observedMinX)...\(observedMaxX) y\(observedMinY)...\(observedMaxY)")
print("qa=OK")
print("atlasPath=\(atlasPath)")
print("previewPath=\(previewPath)")
