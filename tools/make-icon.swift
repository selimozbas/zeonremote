// Renders the ZeonVNC app icon: swift tools/make-icon.swift <out.iconset>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "ZeonVNC.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let k = s / 1024

    // Squircle background
    let inset = 100 * k
    let bgRect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: bgRect, xRadius: 185 * k, yRadius: 185 * k)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 24 * k
    shadow.shadowOffset = NSSize(width: 0, height: -10 * k)
    shadow.set()
    NSColor(calibratedRed: 0.05, green: 0.08, blue: 0.2, alpha: 1).setFill()
    bg.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    NSGradient(colors: [NSColor(calibratedRed: 0.10, green: 0.16, blue: 0.42, alpha: 1),
                        NSColor(calibratedRed: 0.02, green: 0.55, blue: 0.85, alpha: 1)])!
        .draw(in: bg, angle: 70)

    // Monitor
    let screen = NSRect(x: 230 * k, y: 350 * k, width: 564 * k, height: 380 * k)
    let frame = NSBezierPath(roundedRect: screen.insetBy(dx: -22 * k, dy: -22 * k), xRadius: 40 * k, yRadius: 40 * k)
    NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
    frame.fill()
    let glass = NSBezierPath(roundedRect: screen, xRadius: 20 * k, yRadius: 20 * k)
    NSGradient(colors: [NSColor(calibratedRed: 0.04, green: 0.07, blue: 0.18, alpha: 1),
                        NSColor(calibratedRed: 0.08, green: 0.22, blue: 0.45, alpha: 1)])!
        .draw(in: glass, angle: 90)

    // Stand
    let neck = NSBezierPath(roundedRect: NSRect(x: 462 * k, y: 245 * k, width: 100 * k, height: 90 * k), xRadius: 8 * k, yRadius: 8 * k)
    NSColor(calibratedWhite: 0.9, alpha: 1).setFill()
    neck.fill()
    let base = NSBezierPath(roundedRect: NSRect(x: 362 * k, y: 222 * k, width: 300 * k, height: 40 * k), xRadius: 20 * k, yRadius: 20 * k)
    NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
    base.fill()

    // "Z" bolt
    let z = NSBezierPath()
    z.move(to: NSPoint(x: 380 * k, y: 660 * k))
    z.line(to: NSPoint(x: 650 * k, y: 660 * k))
    z.line(to: NSPoint(x: 650 * k, y: 612 * k))
    z.line(to: NSPoint(x: 470 * k, y: 470 * k))
    z.line(to: NSPoint(x: 650 * k, y: 470 * k))
    z.line(to: NSPoint(x: 650 * k, y: 420 * k))
    z.line(to: NSPoint(x: 374 * k, y: 420 * k))
    z.line(to: NSPoint(x: 374 * k, y: 468 * k))
    z.line(to: NSPoint(x: 554 * k, y: 610 * k))
    z.line(to: NSPoint(x: 380 * k, y: 610 * k))
    z.close()
    NSGradient(colors: [NSColor(calibratedRed: 0.35, green: 0.95, blue: 1.0, alpha: 1),
                        NSColor(calibratedRed: 0.2, green: 0.6, blue: 1.0, alpha: 1)])!
        .draw(in: z, angle: -90)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}
