import AppKit

// Renders the app icon into an .iconset directory: swift make_icon.swift <out.iconset>
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    let bg = NSBezierPath(roundedRect: NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s), xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: NSColor(srgbRed: 0.95, green: 0.33, blue: 0.24, alpha: 1),
               ending: NSColor(srgbRed: 0.78, green: 0.12, blue: 0.2, alpha: 1))!.draw(in: bg, angle: -90)
    let page = NSBezierPath(roundedRect: NSRect(x: 270 * s, y: 200 * s, width: 484 * s, height: 624 * s), xRadius: 34 * s, yRadius: 34 * s)
    NSColor.white.setFill(); page.fill()
    NSColor(white: 0.8, alpha: 1).setFill()
    for (i, w) in [300, 360, 250].enumerated() {
        NSBezierPath(roundedRect: NSRect(x: 330 * s, y: CGFloat(700 - i * 70) * s, width: CGFloat(w) * s, height: 26 * s), xRadius: 13 * s, yRadius: 13 * s).fill()
    }
    let ink = NSColor(srgbRed: 0.1, green: 0.25, blue: 0.7, alpha: 1)
    ink.setStroke()
    let box = NSBezierPath(rect: NSRect(x: 330 * s, y: 400 * s, width: 70 * s, height: 70 * s)); box.lineWidth = 12 * s
    NSColor(white: 0.45, alpha: 1).setStroke(); box.stroke()
    let x = NSBezierPath(); x.lineWidth = 16 * s; x.lineCapStyle = .round
    x.move(to: NSPoint(x: 345 * s, y: 415 * s)); x.line(to: NSPoint(x: 385 * s, y: 455 * s))
    x.move(to: NSPoint(x: 345 * s, y: 455 * s)); x.line(to: NSPoint(x: 385 * s, y: 415 * s))
    ink.setStroke(); x.stroke()
    let sig = NSBezierPath(); sig.lineWidth = 16 * s; sig.lineCapStyle = .round; sig.lineJoinStyle = .round
    sig.move(to: NSPoint(x: 330 * s, y: 330 * s))
    sig.curve(to: NSPoint(x: 470 * s, y: 340 * s), controlPoint1: NSPoint(x: 380 * s, y: 440 * s), controlPoint2: NSPoint(x: 420 * s, y: 240 * s))
    sig.curve(to: NSPoint(x: 600 * s, y: 360 * s), controlPoint1: NSPoint(x: 510 * s, y: 440 * s), controlPoint2: NSPoint(x: 560 * s, y: 280 * s))
    sig.stroke()
    // "PDF" badge on the lower right corner of the page.
    let badge = NSBezierPath(roundedRect: NSRect(x: 520 * s, y: 150 * s, width: 330 * s, height: 160 * s), xRadius: 36 * s, yRadius: 36 * s)
    NSColor(srgbRed: 0.75, green: 0.08, blue: 0.16, alpha: 1).setFill()
    badge.fill()
    NSColor.white.setStroke()
    badge.lineWidth = 14 * s
    badge.stroke()
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 118 * s, weight: .heavy),
        .foregroundColor: NSColor.white,
        .paragraphStyle: style,
        .kern: 4 * s,
    ]
    ("PDF" as NSString).draw(in: NSRect(x: 520 * s, y: 160 * s, width: 330 * s, height: 140 * s), withAttributes: attrs)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
