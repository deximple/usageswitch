// Compares two folders of PNG snapshots pixel by pixel. Built and run by scripts/ui-snapshots.sh.
//
// usage: ui-snapshot-diff <baseline-dir> <current-dir> <diff-dir> [--tolerance N]
//        ui-snapshot-diff wraps <dir> <language>...
//
// Every PNG in <current-dir> is compared with the file of the same name in <baseline-dir>. A pixel counts
// as changed when any channel differs by more than N (default 0). For each changed snapshot it prints the
// size of the change and where it is, and writes <diff-dir>/<name>.png: baseline | current | changed
// pixels in magenta. Exit 0 when nothing changed, 1 when something did, 2 on a usage or read error.
//
// `wraps` needs no baseline: it lists the screens that are taller in some languages than in others.
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Snapshots are rendered at 2x; positions are reported in points so they match the layout code.
let scale = 2

struct Bitmap {
    let width: Int
    let height: Int
    /// RGBA, 8 bits per channel, sRGB.
    let pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    init?(png url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { return nil }
        self.init(width: image.width, height: image.height, pixels: pixels)
    }

    var cgImage: CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

struct Change {
    let pixels: Int
    let total: Int
    /// Bounding box of the changed pixels, in pixels from the top-left.
    let minX: Int, maxX: Int, minY: Int, maxY: Int
    /// The current snapshot faded, with every changed pixel in magenta.
    let overlay: Bitmap
}

/// nil when the two bitmaps are equal within `tolerance`. Pixels outside either image count as changed.
func change(from baseline: Bitmap, to current: Bitmap, tolerance: Int) -> Change? {
    if baseline.width == current.width, baseline.height == current.height, baseline.pixels == current.pixels {
        return nil
    }
    let width = max(baseline.width, current.width), height = max(baseline.height, current.height)
    var overlay = [UInt8](repeating: 255, count: width * height * 4)
    var count = 0
    var minX = width, maxX = -1, minY = height, maxY = -1
    for y in 0..<height {
        for x in 0..<width {
            let inBaseline = x < baseline.width && y < baseline.height
            let inCurrent = x < current.width && y < current.height
            let b = (y * baseline.width + x) * 4, c = (y * current.width + x) * 4, o = (y * width + x) * 4
            var changed = !(inBaseline && inCurrent)
            if !changed {
                for channel in 0..<4 where abs(Int(baseline.pixels[b + channel]) - Int(current.pixels[c + channel])) > tolerance {
                    changed = true
                }
            }
            if changed {
                count += 1
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                overlay[o] = 255; overlay[o + 1] = 0; overlay[o + 2] = 160
            } else {
                for channel in 0..<3 { overlay[o + channel] = current.pixels[c + channel] / 3 + 150 }
            }
        }
    }
    guard count > 0 else { return nil }
    return Change(pixels: count, total: width * height, minX: minX, maxX: maxX, minY: minY, maxY: maxY,
                  overlay: Bitmap(width: width, height: height, pixels: overlay))
}

/// baseline | current | overlay, top-aligned on grey with a gutter between them.
func writeSheet(_ panels: [Bitmap], to url: URL) -> Bool {
    let gutter = 24
    let width = panels.map(\.width).reduce(0, +) + gutter * (panels.count + 1)
    let height = (panels.map(\.height).max() ?? 0) + gutter * 2
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
    context.setFillColor(CGColor(gray: 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    var x = gutter
    for panel in panels {
        guard let image = panel.cgImage else { return false }
        // CoreGraphics counts y from the bottom; keep the panels top-aligned.
        context.draw(image, in: CGRect(x: x, y: height - gutter - panel.height, width: panel.width, height: panel.height))
        x += panel.width + gutter
    }
    guard let sheet = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return false }
    CGImageDestinationAddImage(destination, sheet, nil)
    return CGImageDestinationFinalize(destination)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func points(_ pixels: Int) -> Int { pixels / scale }

/// Menu snapshots are as tall as their content, so one that is taller in some languages has text that
/// wrapped there. Names are `<screen>-<language>-<appearance>.png`; fixed-height windows never differ.
func reportWraps(in directory: URL, languages: [String]) {
    var heights: [String: [String: Int]] = [:]
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    for name in names where name.hasSuffix(".png") {
        let stem = name.dropLast(4)
        guard let dash = stem.lastIndex(of: "-"),
              let language = languages.first(where: { stem[..<dash].hasSuffix("-" + $0) }),
              let source = CGImageSourceCreateWithURL(directory.appendingPathComponent(name) as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { continue }
        let screen = String(stem[..<dash].dropLast(language.count + 1))
        heights[screen, default: [:]][language] = max(heights[screen]?[language] ?? 0, points(height))
    }
    for (screen, byLanguage) in heights.sorted(by: { $0.key < $1.key }) {
        guard let shortest = byLanguage.values.min() else { continue }
        let taller = languages.compactMap { language in
            byLanguage[language].flatMap { $0 > shortest ? "\(language) +\($0 - shortest)pt" : nil }
        }
        if !taller.isEmpty { print("WRAPS    \(screen)  \(taller.joined(separator: ", "))") }
    }
}

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "wraps" {
    guard arguments.count >= 3 else { fail("usage: ui-snapshot-diff wraps <dir> <language>...") }
    reportWraps(in: URL(fileURLWithPath: arguments[1]), languages: Array(arguments.dropFirst(2)))
    exit(0)
}
var tolerance = 0
if let flag = arguments.firstIndex(of: "--tolerance") {
    guard flag + 1 < arguments.count, let value = Int(arguments[flag + 1]), (0...255).contains(value) else {
        fail("--tolerance needs a number from 0 to 255")
    }
    tolerance = value
    arguments.removeSubrange(flag...(flag + 1))
}
guard arguments.count == 3 else {
    fail("usage: ui-snapshot-diff <baseline-dir> <current-dir> <diff-dir> [--tolerance N]")
}
let baselineDir = URL(fileURLWithPath: arguments[0]), currentDir = URL(fileURLWithPath: arguments[1])
let diffDir = URL(fileURLWithPath: arguments[2])
let files = FileManager.default
guard let names = try? files.contentsOfDirectory(atPath: currentDir.path).filter({ $0.hasSuffix(".png") }).sorted(),
      !names.isEmpty else { fail("no snapshots in \(currentDir.path)") }
do {
    try? files.removeItem(at: diffDir)
    try files.createDirectory(at: diffDir, withIntermediateDirectories: true)
} catch { fail("cannot create \(diffDir.path): \(error.localizedDescription)") }

var changed = 0, added = 0
for name in names {
    let label = String(name.dropLast(4))
    guard let current = Bitmap(png: currentDir.appendingPathComponent(name)) else { fail("cannot read \(name)") }
    let baselineURL = baselineDir.appendingPathComponent(name)
    guard files.fileExists(atPath: baselineURL.path) else {
        added += 1
        print("NEW      \(label)  (no baseline)")
        continue
    }
    guard let baseline = Bitmap(png: baselineURL) else { fail("cannot read baseline \(name)") }
    guard let change = change(from: baseline, to: current, tolerance: tolerance) else { continue }
    changed += 1
    let sheet = diffDir.appendingPathComponent(name)
    guard writeSheet([baseline, current, change.overlay], to: sheet) else { fail("cannot write \(sheet.path)") }
    let share = String(format: "%.2f%%", Double(change.pixels) * 100 / Double(change.total))
    var line = "CHANGED  \(label)  \(change.pixels) px (\(share))"
        + "  x \(points(change.minX))–\(points(change.maxX))pt  y \(points(change.minY))–\(points(change.maxY))pt"
    if baseline.width != current.width || baseline.height != current.height {
        line += "  size \(points(baseline.width))×\(points(baseline.height))pt → \(points(current.width))×\(points(current.height))pt"
    }
    print(line)
}
// Snapshots the baseline has and this run did not render: filtered out, or no longer in the matrix.
let baselineOnly = ((try? files.contentsOfDirectory(atPath: baselineDir.path)) ?? [])
    .filter { $0.hasSuffix(".png") && !names.contains($0) }.count
print("\(names.count) compared: \(changed) changed, \(added) new"
    + (baselineOnly > 0 ? ", \(baselineOnly) only in the baseline" : "")
    + (changed > 0 ? " — see \(diffDir.path)" : ""))
exit(changed > 0 ? 1 : 0)
