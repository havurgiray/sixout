import AppKit

// SixOut logo: the glyphs ❨⑥❩ on a rounded square.
func draw(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let inset = size * 0.04
    let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let path = CGPath(roundedRect: rect, cornerWidth: size * 0.22, cornerHeight: size * 0.22, transform: nil)
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    let colors = [NSColor(calibratedRed: 0.13, green: 0.15, blue: 0.24, alpha: 1).cgColor, NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.10, alpha: 1).cgColor] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])
    ctx.restoreGState()
    let accent = NSColor(calibratedRed: 0.36, green: 0.78, blue: 1.0, alpha: 1)
    let font = NSFont.systemFont(ofSize: size * 0.5, weight: .medium)
    let str = NSMutableAttributedString(string: "❨⑥❩", attributes: [.font: font, .foregroundColor: NSColor.white])
    str.addAttribute(.foregroundColor, value: accent, range: NSRange(location: 1, length: 1))
    let s = str.size()
    str.draw(at: NSPoint(x: size / 2 - s.width / 2, y: size / 2 - s.height / 2 + size * 0.02))
    img.unlockFocus()
    return img
}
let out = CommandLine.arguments[1]
let rep = NSBitmapImageRep(data: draw(size: 1024).tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
