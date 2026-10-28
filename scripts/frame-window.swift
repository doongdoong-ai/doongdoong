// Wraps an unmodified app capture in macOS window chrome. Usage: frame-window INPUT.png OUTPUT.png
import AppKit

/// Traffic lights in window points, drawn at `scale`. render-readme-tour.swift keeps the same geometry.
func drawTrafficLights(in rect: NSRect, scale: CGFloat) {
    let colors = [(0xFF5F57, 0xE0443E), (0xFEBC2E, 0xDEA123), (0x28C840, 0x1AAB29)]
    for (i, (fill, stroke)) in colors.enumerated() {
        let d = 12 * scale, cx = rect.minX + (20 + CGFloat(i) * 20) * scale, cy = rect.maxY - 18 * scale
        let dot = NSBezierPath(ovalIn: NSRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d))
        NSColor(hex: fill).setFill(); dot.fill()
        NSColor(hex: stroke).setStroke(); dot.lineWidth = 0.5 * scale; dot.stroke()
    }
}
extension NSColor {
    convenience init(hex: Int) { self.init(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1) }
}

let image = NSImage(contentsOfFile: CommandLine.arguments[1])!
let margin: CGFloat = 56, radius: CGFloat = 16
let size = NSSize(width: image.size.width + margin * 2, height: image.size.height + margin * 2)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let window = NSRect(x: margin, y: margin, width: image.size.width, height: image.size.height)
let shape = NSBezierPath(roundedRect: window, xRadius: radius, yRadius: radius)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.22); shadow.shadowBlurRadius = 36; shadow.shadowOffset = NSSize(width: 0, height: -14); shadow.set()
NSColor.white.setFill(); shape.fill()
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.saveGraphicsState()
shape.addClip()
image.draw(in: window)
NSGraphicsContext.restoreGraphicsState()
drawTrafficLights(in: window, scale: 1)
NSColor.black.withAlphaComponent(0.12).setStroke()
let border = NSBezierPath(roundedRect: window.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius); border.lineWidth = 0.5; border.stroke()
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
