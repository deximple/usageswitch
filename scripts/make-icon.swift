// Renders the app icon as an .iconset: a warm paper tile holding three account rows, each a
// remaining-usage meter; the first row is the current account in system blue. No vendor colors or marks.
// Sizes of 32px and below drop the account dots and thicken the meters so they stay legible.
// Usage: swift scripts/make-icon.swift build/AppIcon.iconset && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// Geometry is in a 1024-unit canvas, y-down. The tile is Apple's macOS icon template squircle.
let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let tileRadius: CGFloat = 185.4
let tileTop: UInt32 = 0xF7F6F3, tileBottom: UInt32 = 0xE9E7E2
let ink: UInt32 = 0x26282D, current: UInt32 = 0x0A7AFF, track: UInt32 = 0xD9D6CF

struct Row { let y: CGFloat; let remaining: CGFloat; let color: UInt32 }

func srgb(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

func continuous(_ rect: CGRect, radius: CGFloat) -> CGPath {
    RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
}

// Round-ended like the app's own usage bars (SwiftUI Capsule).
func capsule(_ rect: CGRect) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil)
}

func fill(_ ctx: CGContext, _ path: CGPath, _ hex: UInt32) {
    ctx.setFillColor(srgb(hex)); ctx.addPath(path); ctx.fillPath()
}

func drawTile(_ ctx: CGContext) {
    ctx.saveGState()
    ctx.addPath(continuous(tileRect, radius: tileRadius))
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [srgb(tileTop), srgb(tileBottom)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: tileRect.minY), end: CGPoint(x: 512, y: tileRect.maxY), options: [])
    ctx.restoreGState()
}

// A neutral track with the remaining share filled from the left; the fill never shrinks below a circle.
func drawMeter(_ ctx: CGContext, x: CGFloat, width: CGFloat, height: CGFloat, row: Row) {
    let trackRect = CGRect(x: x, y: row.y - height / 2, width: width, height: height)
    fill(ctx, capsule(trackRect), track)
    let fillRect = CGRect(x: x, y: trackRect.minY, width: max(height, width * row.remaining), height: height)
    fill(ctx, capsule(fillRect), row.color)
}

func drawRows(_ ctx: CGContext, px: Int) {
    if px <= 32 {
        // 64-unit grid = whole pixels at 16px: 2px meters, 1px gaps, filled 8, 5 and 2 of 10px.
        let rows = [Row(y: 320, remaining: 0.8, color: current), Row(y: 512, remaining: 0.5, color: ink),
                    Row(y: 704, remaining: 0.2, color: ink)]
        rows.forEach { drawMeter(ctx, x: 192, width: 640, height: 128, row: $0) }
        return
    }
    let rows = [Row(y: 362, remaining: 0.82, color: current), Row(y: 512, remaining: 0.5, color: ink),
                Row(y: 662, remaining: 0.22, color: ink)]
    for row in rows {
        ctx.setFillColor(srgb(row.color))
        ctx.fillEllipse(in: CGRect(x: 231 - 46, y: row.y - 46, width: 92, height: 92))
        drawMeter(ctx, x: 315, width: 524, height: 76, row: row)
    }
}

func renderPNG(px: Int, to url: URL) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: CGFloat(px) / 1024, y: -CGFloat(px) / 1024)
    drawTile(ctx)
    drawRows(ctx, px: px)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift scripts/make-icon.swift <output.iconset>\n".utf8))
    exit(64)
}
let dir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    renderPNG(px: px, to: dir.appendingPathComponent("icon_\(name).png"))
}
