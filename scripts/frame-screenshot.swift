#!/usr/bin/env swift
// Frames a raw snapshot PNG for the README: rounded corners, hairline border,
// soft drop shadow, transparent padding.
// usage: swift scripts/frame-screenshot.swift <in.png> <out.png> [--dark]
import AppKit

let args = CommandLine.arguments
guard args.count >= 3 else {
    fputs("usage: frame-screenshot.swift <in.png> <out.png> [--dark]\n", stderr); exit(2)
}
guard let src = try? NSBitmapImageRep(data: Data(contentsOf: URL(fileURLWithPath: args[1]))) else {
    fputs("cannot read \(args[1])\n", stderr); exit(1)
}
let dark = args.contains("--dark")
let w = src.pixelsWide, h = src.pixelsHigh
let pad = 48, radius = CGFloat(20)  // 10pt corner radius at 2x, pad leaves room for the shadow

let out = NSBitmapImageRep(bitmapDataPlanes: nil,
                           pixelsWide: w + 2 * pad, pixelsHigh: h + 2 * pad,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .calibratedRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: out.pixelsWide, height: out.pixelsHigh).fill()

let rect = NSRect(x: pad, y: pad, width: w, height: h)
let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -10)
NSGraphicsContext.current?.saveGraphicsState()
shadow.set()
NSColor.white.setFill()
path.fill()
NSGraphicsContext.current?.restoreGraphicsState()

path.addClip()
src.draw(in: rect)

(dark ? NSColor.white.withAlphaComponent(0.12)
      : NSColor.black.withAlphaComponent(0.12)).setStroke()
path.lineWidth = 2
path.stroke()
NSGraphicsContext.restoreGraphicsState()

guard let png = out.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: args[2]))
