// Generates AppIcon.icns: `swift icon.swift` (build.sh runs it when the icon is missing).
// `swift icon.swift preview.png` writes a single 1024 px image instead.
//
// Mark: the letter K in SF Rounded, split in two colours. The stem is the structure (tables and
// schema: still, so a neutral cream); the arms are the query reaching out from it (turmeric, the
// one accent). Forest green ground: calm for long sessions, and a nod to "kueri" being Indonesian.
import AppKit

func hex(_ v: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}
let forest = hex(0x1F3A2E)   // ground
let cream = hex(0xF5E8D3)    // stem, 10.2:1 on forest
let turmeric = hex(0xE8A338) // arms, 5.7:1 on forest

/// The K glyph as a path on the 1024 grid, `height` tall, centred.
func letterK(height: CGFloat) -> NSBezierPath {
    let base = NSFont.systemFont(ofSize: 200, weight: .semibold)
    let font = NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: 200) ?? base
    var ch: UniChar = 0x4B, glyph: CGGlyph = 0
    CTFontGetGlyphsForCharacters(font as CTFont, &ch, &glyph, 1)
    let path = NSBezierPath(cgPath: CTFontCreatePathForGlyph(font as CTFont, glyph, nil)!)
    let b = path.bounds, s = height / b.height
    var t = AffineTransform(translationByX: -b.midX, byY: -b.midY)
    t.append(AffineTransform(scaleByX: s, byY: s))
    t.append(AffineTransform(translationByX: 512, byY: 512))
    path.transform(using: t)
    return path
}

/// Right edge of the stem: walk along a line near the top, through the first filled run.
func stemRight(_ p: NSBezierPath) -> CGFloat {
    let b = p.bounds, y = b.minY + b.height * 0.9
    var x = b.minX + 1
    while x < b.maxX, !p.contains(NSPoint(x: x, y: y)) { x += 1 }
    while x < b.maxX, p.contains(NSPoint(x: x, y: y)) { x += 1 }
    return x
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.cgContext.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)

    // macOS icon grid: 824 body, 185 corner radius; the drop shadow is the system's icon convention.
    let body = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 18
    shadow.shadowOffset = NSSize(width: 0, height: -8)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    forest.setFill()
    body.fill()
    NSGraphicsContext.restoreGraphicsState()

    let k = letterK(height: 500)
    let split = stemRight(k)
    for (area, color) in [(NSRect(x: 0, y: 0, width: split, height: 1024), cream),
                          (NSRect(x: split, y: 0, width: 1024 - split, height: 1024), turmeric)] {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: area).addClip()
        color.setFill()
        k.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}

if CommandLine.arguments.count > 1 {
    try! render(1024).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    exit(0)
}
let dir = URL(fileURLWithPath: "AppIcon.iconset")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: dir.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: dir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
