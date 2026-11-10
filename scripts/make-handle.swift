// Joonistab „by jonzethan“ Chrova fondiga valgeks läbipaistva taustaga PNG-ks (äpp värvib selle ise neoonsiniseks).
// Fonti ennast repos ega äpis pole (demo litsents = ainult isiklik kasutus); repos on ainult see pilt.
// Kasutus: swift scripts/make-handle.swift ~/Downloads/chrova-demo/Chrova-Demo.otf Resources/handle.png ["by jonzethan"]
import AppKit
let args = CommandLine.arguments
let url = URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath) as CFURL
CTFontManagerRegisterFontsForURL(url, .process, nil)
let desc = (CTFontManagerCreateFontDescriptorsFromURL(url) as! [CTFontDescriptor])[0]
let name = CTFontDescriptorCopyAttribute(desc, kCTFontNameAttribute) as! String
let font = NSFont(name: name, size: 160)!
let text = NSAttributedString(string: args.count > 3 ? args[3] : "by jonzethan", attributes: [.font: font, .foregroundColor: NSColor.white, .kern: 4])
let b = text.boundingRect(with: NSSize(width: 10000, height: 1000), options: [.usesLineFragmentOrigin, .usesDeviceMetrics])
let pad = 8.0
let size = NSSize(width: ceil(b.width + pad * 2), height: ceil(b.height + pad * 2))
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
text.draw(at: NSPoint(x: pad - b.minX, y: pad - b.minY))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("\(args[2]): \(Int(size.width))x\(Int(size.height)) (\(name))")
