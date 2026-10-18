// Renders Resources/AppIcon.icns: warm paper tile, two overlapping account discs (clay + indigo) and a swap arc.
import AppKit
func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let inset = s * 0.09
    let tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    ctx.addPath(CGPath(roundedRect: tile, cornerWidth: s * 0.2, cornerHeight: s * 0.2, transform: nil))
    ctx.setFillColor(NSColor(srgbRed: 0.965, green: 0.949, blue: 0.918, alpha: 1).cgColor)
    ctx.fillPath()
    let r = s * 0.2
    let back = CGRect(x: s * 0.5 - r * 0.15, y: s * 0.5 - r * 0.55, width: r * 2, height: r * 2)
    ctx.setFillColor(NSColor(srgbRed: 0.31, green: 0.33, blue: 0.72, alpha: 1).cgColor)
    ctx.fillEllipse(in: back)
    let front = CGRect(x: s * 0.5 - r * 1.85, y: s * 0.5 - r * 1.45, width: r * 2, height: r * 2)
    ctx.setFillColor(NSColor(srgbRed: 0.757, green: 0.373, blue: 0.235, alpha: 1).cgColor)
    ctx.fillEllipse(in: front)
    ctx.setStrokeColor(NSColor(srgbRed: 0.965, green: 0.949, blue: 0.918, alpha: 1).cgColor)
    ctx.setLineWidth(s * 0.028)
    ctx.strokeEllipse(in: front)
    ctx.setStrokeColor(NSColor(srgbRed: 0.165, green: 0.141, blue: 0.114, alpha: 1).cgColor)
    ctx.setLineWidth(s * 0.035)
    ctx.setLineCap(.round)
    ctx.addArc(center: CGPoint(x: s * 0.5, y: s * 0.5), radius: s * 0.33, startAngle: .pi * 0.15, endAngle: .pi * 0.62, clockwise: false)
    ctx.strokePath()
    let tip = CGPoint(x: s * 0.5 + s * 0.33 * cos(.pi * 0.62), y: s * 0.5 + s * 0.33 * sin(.pi * 0.62))
    ctx.move(to: CGPoint(x: tip.x + s * 0.07, y: tip.y + s * 0.01)); ctx.addLine(to: tip); ctx.addLine(to: CGPoint(x: tip.x + s * 0.035, y: tip.y - s * 0.06))
    ctx.strokePath()
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}
let dir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: dir.appendingPathComponent("icon_\(name).png"))
}
