// Joonistab Androidi ikooni (res/drawable/ic_launcher_fg.xml) Maci AppIcon.icns-iks.
// Käivita: swift scripts/make-icon.swift  (kirjutab Resources/AppIcon.icns)
import AppKit

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px)
    // Maci ikooni ruudustik: ümardatud ruut ~80% suurusest
    let inset = s * 0.1, side = s - 2 * inset
    let tile = CGPath(roundedRect: CGRect(x: inset, y: inset, width: side, height: side),
                      cornerWidth: side * 0.225, cornerHeight: side * 0.225, transform: nil)
    ctx.addPath(tile); ctx.setFillColor(CGColor(srgbRed: 0x07/255, green: 0x09/255, blue: 0x0C/255, alpha: 1)); ctx.fillPath()
    ctx.addPath(tile); ctx.setStrokeColor(CGColor(srgbRed: 0x1B/255, green: 0x22/255, blue: 0x2B/255, alpha: 1))
    ctx.setLineWidth(s * 0.006); ctx.strokePath()
    // Android 108 vp -> keskmine osa (logo raadius 24) suurendatud ruudu sisse
    let k = side / 60.0
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: s / 2 + (x - 54) * k, y: s / 2 - (y - 54) * k) }
    let c = p(54, 54)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(CGColor(srgbRed: 0x2A/255, green: 0x34/255, blue: 0x40/255, alpha: 1)); ctx.setLineWidth(2 * k)
    ctx.addArc(center: c, radius: 24 * k, startAngle: 0, endAngle: .pi * 2, clockwise: false); ctx.strokePath()
    // tsüaan kaar: ülevalt (54,30) päripäeva punktini (77,47)
    let a0 = CGFloat.pi / 2, a1 = atan2(CGFloat(7), CGFloat(23))
    ctx.setStrokeColor(CGColor(srgbRed: 0x5E/255, green: 0xE6/255, blue: 0xFF/255, alpha: 1)); ctx.setLineWidth(2.4 * k)
    ctx.addArc(center: c, radius: 24 * k, startAngle: a0, endAngle: a1, clockwise: true); ctx.strokePath()
    ctx.setFillColor(CGColor(srgbRed: 1, green: 0x33/255, blue: 0x47/255, alpha: 0x40/255.0))
    ctx.fillEllipse(in: CGRect(x: c.x - 14 * k, y: c.y - 14 * k, width: 28 * k, height: 28 * k))
    ctx.setFillColor(CGColor(srgbRed: 1, green: 0x33/255, blue: 0x47/255, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: c.x - 9 * k, y: c.y - 9 * k, width: 18 * k, height: 18 * k))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: dir)
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! draw(base).write(to: dir.appendingPathComponent("icon_\(base)x\(base).png"))
    try! draw(base * 2).write(to: dir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", dir.path, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
try! draw(512).write(to: URL(fileURLWithPath: NSTemporaryDirectory() + "kirjuta-icon-preview.png"))
print(p.terminationStatus == 0 ? "Resources/AppIcon.icns" : "iconutil viga")
