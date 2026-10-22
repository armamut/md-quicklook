// Draws the app icon and writes macos/App/AppIcon.icns.
// Usage: swift scripts/make-icon.swift
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s, y: s)

    // Rounded-square base with a subtle vertical gradient (macOS icon grid: 824pt body).
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor(srgbRed: 0.10, green: 0.12, blue: 0.15, alpha: 1).setFill()
    shape.fill()
    ctx.restoreGState()
    NSGradient(colors: [NSColor(srgbRed: 0.20, green: 0.23, blue: 0.29, alpha: 1),
                        NSColor(srgbRed: 0.08, green: 0.09, blue: 0.12, alpha: 1)])!
        .draw(in: shape, angle: -90)

    // Page.
    let page = NSBezierPath(roundedRect: CGRect(x: 262, y: 210, width: 500, height: 610), xRadius: 36, yRadius: 36)
    NSColor(white: 0.98, alpha: 1).setFill()
    page.fill()

    // "M↓" mark.
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 250, weight: .heavy),
        .foregroundColor: NSColor(srgbRed: 0.12, green: 0.14, blue: 0.17, alpha: 1),
        .kern: -6,
    ]
    let mark = NSAttributedString(string: "M↓", attributes: attrs)
    let size = mark.size()
    mark.draw(at: CGPoint(x: 512 - size.width / 2, y: 470))

    // Text lines, the last one accented.
    let lines: [(CGFloat, CGFloat, NSColor)] = [
        (420, 400, NSColor(white: 0.78, alpha: 1)),
        (360, 400, NSColor(white: 0.78, alpha: 1)),
        (300, 250, NSColor(srgbRed: 0.04, green: 0.41, blue: 0.85, alpha: 1)),
    ]
    for (y, w, c) in lines {
        c.setFill()
        NSBezierPath(roundedRect: CGRect(x: 312, y: y, width: w, height: 30), xRadius: 15, yRadius: 15).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "macos/App/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! task.run()
task.waitUntilExit()
print("wrote \(out.path)")
try! render(512).write(to: URL(fileURLWithPath: "docs/icon.png"))
