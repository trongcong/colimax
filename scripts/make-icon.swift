// Draws the ColimaX icon (1024×1024) with CoreGraphics and writes the .icns directly (no iconutil).
// Usage: swiftc scripts/make-icon.swift -o /tmp/make-icon && /tmp/make-icon <AppIcon.icns> <AppIcon-1024.png>
// Design: CX monogram, a white C wrapping an orange X on a midnight-blue to teal gradient squircle.
// The same geometry is used by MenuBarIcon.swift and the menu bar glyph in site/index.html.
import AppKit

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no context") }
    let s = size / 1024

    // macOS icon grid: 824×824 body with a 100 px margin.
    let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let corner = 185 * s
    let bodyPath = CGPath(roundedRect: body, cornerWidth: corner, cornerHeight: corner, transform: nil)

    // Subtle drop shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(bodyPath)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Background gradient: midnight blue (top left) to dark teal (bottom right).
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let colors = [
        NSColor(red: 0x0E / 255, green: 0x17 / 255, blue: 0x29 / 255, alpha: 1).cgColor,
        NSColor(red: 0x13 / 255, green: 0x4E / 255, blue: 0x4A / 255, alpha: 1).cgColor,
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
    ctx.restoreGState()

    // CX monogram (CoreGraphics coordinates, origin at bottom left).
    ctx.setLineCap(.round)

    // White C: arc with r = 230, open on the right, ends at x = 640, y = 512 ± 182.
    let angle = atan2(182.0, 140.6)
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(92 * s)
    ctx.addArc(center: CGPoint(x: 499.4 * s, y: 512 * s), radius: 230 * s,
               startAngle: angle, endAngle: -angle, clockwise: false)
    ctx.strokePath()

    // Orange X sits in the C's opening.
    ctx.setStrokeColor(NSColor(red: 1.0, green: 0x8A / 255, blue: 0x3D / 255, alpha: 1).cgColor)
    ctx.setLineWidth(78 * s)
    for (a, b) in [((560.0, 604.0), (760.0, 404.0)), ((760.0, 604.0), (560.0, 404.0))] {
        ctx.move(to: CGPoint(x: a.0 * s, y: a.1 * s))
        ctx.addLine(to: CGPoint(x: b.0 * s, y: b.1 * s))
    }
    ctx.strokePath()

    image.unlockFocus()
    return image
}

func pngData(_ image: NSImage, pixels: Int) throws -> Data {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { throw CocoaError(.fileWriteUnknown) }
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    return data
}

/// ICNS = "icns" + total length (big-endian) + blocks of [4-byte type][block length][PNG].
func icnsData(_ image: NSImage) throws -> Data {
    let entries: [(String, Int)] = [
        ("icp4", 16), ("ic11", 32), ("icp5", 32), ("ic12", 64), ("ic07", 128),
        ("ic13", 256), ("ic08", 256), ("ic14", 512), ("ic09", 512), ("ic10", 1024),
    ]
    func be32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).bigEndian) { Data($0) } }
    var body = Data()
    for (code, pixels) in entries {
        let png = try pngData(image, pixels: pixels)
        body += Data(code.utf8) + be32(png.count + 8) + png
    }
    return Data("icns".utf8) + be32(body.count + 8) + body
}

let args = CommandLine.arguments
guard args.count == 3 else {
    print("Usage: make-icon <AppIcon.icns> <AppIcon-1024.png>")
    exit(2)
}
let master = drawIcon(size: 1024)
try icnsData(master).write(to: URL(fileURLWithPath: args[1]))
try pngData(master, pixels: 1024).write(to: URL(fileURLWithPath: args[2]))
print("Wrote \(args[1]) and \(args[2])")
