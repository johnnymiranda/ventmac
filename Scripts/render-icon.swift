// render-icon.swift — Programmatically render the VentMac app icon base PNG.
//
// Draws a 1024x1024 macOS Big Sur–style tile: a rounded-rectangle (squircle)
// with a vertical blue→indigo gradient and a centered white voice waveform
// glyph (seven rounded bars in a symmetric audio-level pattern). No external
// assets or network access — pure AppKit / CoreGraphics.
//
// Usage: swift render-icon.swift [output.png]   (default: Scripts/icon-1024.png)

import AppKit
import CoreGraphics
import Foundation

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Scripts/icon-1024.png"

let dim = 1024
let colorSpace = CGColorSpaceCreateDeviceRGB()

guard let ctx = CGContext(
    data: nil,
    width: dim,
    height: dim,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    FileHandle.standardError.write("Failed to create CGContext\n".data(using: .utf8)!)
    exit(1)
}

ctx.setAllowsAntialiasing(true)
ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high
ctx.clear(CGRect(x: 0, y: 0, width: dim, height: dim))

// --- Tile geometry -----------------------------------------------------------
// macOS applies its own mask, but a ~100px transparent margin around an ~824px
// squircle matches the Big Sur icon grid so the tile reads correctly.
let margin: CGFloat = 100
let tile = CGRect(x: margin, y: margin,
                  width: CGFloat(dim) - 2 * margin,
                  height: CGFloat(dim) - 2 * margin)
let corner: CGFloat = 185 // ~0.224 of the tile edge, the Big Sur ratio
let tilePath = CGPath(roundedRect: tile, cornerWidth: corner, cornerHeight: corner, transform: nil)

func srgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

// --- Background: vertical blue → indigo gradient -----------------------------
ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()

let topColor = srgb(79, 125, 246)    // #4F7DF6
let bottomColor = srgb(58, 85, 217)  // #3A55D9
let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [topColor, bottomColor] as CFArray,
    locations: [0, 1]
)!
// CG origin is bottom-left, so the visual top of the tile is at maxY.
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: tile.midX, y: tile.maxY),
    end: CGPoint(x: tile.midX, y: tile.minY),
    options: []
)

// Subtle top sheen for a little material depth.
let sheen = CGGradient(
    colorsSpace: colorSpace,
    colors: [srgb(255, 255, 255, 0.16), srgb(255, 255, 255, 0)] as CFArray,
    locations: [0, 1]
)!
ctx.drawRadialGradient(
    sheen,
    startCenter: CGPoint(x: tile.midX, y: tile.maxY),
    startRadius: 0,
    endCenter: CGPoint(x: tile.midX, y: tile.maxY),
    endRadius: tile.width * 0.85,
    options: []
)
ctx.restoreGState()

// --- Foreground: white voice waveform ---------------------------------------
// Seven rounded bars, symmetric height pattern, centered on the tile midline.
let heights: [CGFloat] = [0.45, 0.85, 0.60, 1.00, 0.60, 0.85, 0.45]
let barCount = heights.count
let gapRatio: CGFloat = 0.62 // gap width as a fraction of bar width

let glyphWidth = tile.width * 0.54
// glyphWidth = barCount*bw + (barCount-1)*gap, gap = gapRatio*bw
let barWidth = glyphWidth / (CGFloat(barCount) + CGFloat(barCount - 1) * gapRatio)
let gap = barWidth * gapRatio
let maxBarHeight = tile.height * 0.50

let firstX = tile.midX - glyphWidth / 2
let midY = tile.midY

// Soft shadow lifts the glyph off the gradient.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8),
              blur: 22,
              color: srgb(20, 30, 90, 0.28))
ctx.setFillColor(srgb(255, 255, 255))

for (i, frac) in heights.enumerated() {
    let x = firstX + CGFloat(i) * (barWidth + gap)
    let h = maxBarHeight * frac
    let barRect = CGRect(x: x, y: midY - h / 2, width: barWidth, height: h)
    let barPath = CGPath(
        roundedRect: barRect,
        cornerWidth: barWidth / 2,
        cornerHeight: barWidth / 2,
        transform: nil
    )
    ctx.addPath(barPath)
    ctx.fillPath()
}
ctx.restoreGState()

// --- Encode PNG --------------------------------------------------------------
guard let image = ctx.makeImage() else {
    FileHandle.standardError.write("Failed to make CGImage\n".data(using: .utf8)!)
    exit(1)
}
let rep = NSBitmapImageRep(cgImage: image)
guard let pngData = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("Failed to encode PNG\n".data(using: .utf8)!)
    exit(1)
}
try pngData.write(to: URL(fileURLWithPath: outputPath))
print("Rendered \(dim)x\(dim) icon → \(outputPath)")
