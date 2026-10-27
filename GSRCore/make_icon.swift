// Draws the app icon (a mixer: three faders and a level meter that ends in red) and writes the sizes of an .iconset.
// Usage: swift make_icon.swift OUT.iconset      then: iconutil -c icns OUT.iconset
import AppKit

func draw(_ s: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(s), pixelsHigh: Int(s), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let c = NSGraphicsContext.current!.cgContext
    let u = s / 1024
    func rr(_ r: CGRect, _ radius: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil) }
    // the plate: macOS icon grid, 824 points of 1024
    let plate = CGRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    c.saveGState()
    c.addPath(rr(plate, 185 * u)); c.clip()
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [NSColor(calibratedRed: 0.20, green: 0.23, blue: 0.29, alpha: 1).cgColor, NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.11, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(grad, start: CGPoint(x: 0, y: plate.maxY), end: CGPoint(x: 0, y: plate.minY), options: [])
    // three faders
    for (i, knob) in [0.62, 0.35, 0.50].enumerated() {
        let x = (230 + CGFloat(i) * 150) * u
        c.setFillColor(NSColor(white: 0.03, alpha: 1).cgColor)
        c.addPath(rr(CGRect(x: x - 14 * u, y: 250 * u, width: 28 * u, height: 520 * u), 14 * u)); c.fillPath()
        let ky = (250 + knob * 440) * u
        c.setFillColor(NSColor(white: 0.86, alpha: 1).cgColor)
        c.addPath(rr(CGRect(x: x - 52 * u, y: ky, width: 104 * u, height: 70 * u), 14 * u)); c.fillPath()
        c.setFillColor(NSColor(white: 0.2, alpha: 1).cgColor)
        c.fill(CGRect(x: x - 40 * u, y: ky + 32 * u, width: 80 * u, height: 6 * u))
    }
    // the level meter: green, then orange, then red at the top
    let segs = 10
    for k in 0..<segs {
        let y = (250 + CGFloat(k) * 52) * u
        let colour: NSColor = k >= 8 ? .systemRed : k >= 6 ? .systemOrange : .systemGreen
        c.setFillColor(colour.withAlphaComponent(k <= 8 ? 1 : 0.95).cgColor)
        c.addPath(rr(CGRect(x: 690 * u, y: y, width: 120 * u, height: 38 * u), 8 * u)); c.fillPath()
    }
    c.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    let rep = draw(CGFloat(px))
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
