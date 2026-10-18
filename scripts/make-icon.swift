import AppKit
import CoreText

private let ink: UInt32 = 0x292B27
private let tile: UInt32 = 0x191B1E
private let light: UInt32 = 0xF8F8F4

private func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}

private func bitmap(width: Int, height: Int, draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
    let context = NSGraphicsContext.current!.cgContext
    context.setAllowsAntialiasing(true)
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    draw(context)
    NSGraphicsContext.restoreGraphicsState()
    return image
}

private func drawIcon(_ context: CGContext, in frame: CGRect) {
    context.saveGState()
    context.translateBy(x: frame.minX, y: frame.minY)
    context.scaleBy(x: frame.width / 100, y: frame.height / 100)
    context.addPath(CGPath(roundedRect: CGRect(x: 6, y: 6, width: 88, height: 88),
                           cornerWidth: 20, cornerHeight: 20, transform: nil))
    context.setFillColor(color(tile).cgColor)
    context.fillPath()
    context.addPath(BrandSymbol.fitted(in: CGRect(x: 22, y: 21, width: 56, height: 58)))
    context.setFillColor(color(light).cgColor)
    context.drawPath(using: .eoFill)
    context.restoreGState()
}

private func icon(_ size: Int) -> NSBitmapImageRep {
    bitmap(width: size, height: size) { drawIcon($0, in: CGRect(x: 0, y: 0, width: size, height: size)) }
}

private func svgPath(_ path: CGPath) -> String {
    func value(_ n: CGFloat) -> String { String(format: "%.4f", Double(n)) }
    func point(_ p: CGPoint) -> String { "\(value(p.x)) \(value(p.y))" }
    var commands: [String] = []
    path.applyWithBlock { pointer in
        let e = pointer.pointee
        switch e.type {
        case .moveToPoint: commands.append("M" + point(e.points[0]))
        case .addLineToPoint: commands.append("L" + point(e.points[0]))
        case .addQuadCurveToPoint: commands.append("Q" + point(e.points[0]) + " " + point(e.points[1]))
        case .addCurveToPoint: commands.append("C" + point(e.points[0]) + " " + point(e.points[1]) + " " + point(e.points[2]))
        case .closeSubpath: commands.append("Z")
        @unknown default: break
        }
    }
    return commands.joined(separator: " ")
}

/// Outlined Korean lettering keeps exported SVGs independent of installed fonts.
private func lettering() -> CGPath {
    let font = NSFont(name: "AppleSDGothicNeo-SemiBold", size: 76) ?? NSFont.systemFont(ofSize: 76, weight: .semibold)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "붕붕이", attributes: [.font: font, .kern: -1.6]))
    let result = CGMutablePath()
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let count = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
        CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
        let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
        for i in 0..<count {
            guard let glyph = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) else { continue }
            var transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 98 + positions[i].x, ty: 90 - positions[i].y)
            result.addPath(glyph.copy(using: &transform)!)
        }
    }
    return result
}

private func fitted(_ path: CGPath, in frame: CGRect) -> CGPath {
    let bounds = path.boundingBoxOfPath
    let scale = min(frame.width / bounds.width, frame.height / bounds.height)
    var t = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
        tx: frame.midX - bounds.midX * scale, ty: frame.midY - bounds.midY * scale)
    return path.copy(using: &t)!
}

private func png(_ image: NSBitmapImageRep, to url: URL) throws {
    try image.representation(using: .png, properties: [:])!.write(to: url, options: .atomic)
}

@main
struct MakeIcon {
    static func main() throws {
        guard CommandLine.arguments.count > 1 else { fatalError("Usage: make-icon <directory> [--brand-preview]") }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Each build owns its temporary iconset, so preview and packaging can run independently.
        let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("bungbungi-\(UUID().uuidString).iconset")
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: iconset) }
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let suffix = scale == 2 ? "@2x" : ""
                try png(icon(size * scale), to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
            }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        process.arguments = ["-c", "icns", iconset.path, "-o", directory.appendingPathComponent("AppIcon.icns").path]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { exit(1) }

        guard CommandLine.arguments.contains("--brand-preview") else { return }
        try png(icon(1024), to: directory.appendingPathComponent("app-icon.png"))
        let symbol = BrandSymbol.fitted(in: CGRect(x: 5, y: 5, width: 90, height: 90))
        for (name, fill) in [("mark.svg", "#292B27"), ("mark-light.svg", "#F8F8F4")] {
            let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" width="100" height="100" viewBox="0 0 100 100" role="img" aria-labelledby="title desc">
              <title id="title">붕붕이 심볼</title>
              <desc id="desc">두 번의 소리를 표현한 기울어진 두 개의 둥근 루프. 같은 두께와 간격으로 이어지는 단색 심볼.</desc>
              <path fill="\(fill)" fill-rule="evenodd" d="\(svgPath(symbol))"/>
            </svg>
            """
            try Data((svg + "\n").utf8).write(to: directory.appendingPathComponent(name), options: .atomic)
        }
        let appSVG = """
        <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 100 100" role="img" aria-labelledby="title desc">
          <title id="title">붕붕이 앱 아이콘</title>
          <desc id="desc">짙은 흑연색의 둥근 사각형 위에 놓인 밝은 두 개의 루프.</desc>
          <rect x="6" y="6" width="88" height="88" rx="20" fill="#191B1E"/>
          <path fill="#F8F8F4" fill-rule="evenodd" d="\(svgPath(BrandSymbol.fitted(in: CGRect(x: 22, y: 21, width: 56, height: 58))))"/>
        </svg>
        """
        try Data((appSVG + "\n").utf8).write(to: directory.appendingPathComponent("app-icon.svg"), options: .atomic)
        let wordmark = CGMutablePath()
        wordmark.addPath(BrandSymbol.fitted(in: CGRect(x: 4, y: 22, width: 64, height: 76)))
        wordmark.addPath(lettering())
        let wordSVG = """
        <svg xmlns="http://www.w3.org/2000/svg" width="330" height="120" viewBox="0 0 330 120" role="img" aria-labelledby="title desc">
          <title id="title">붕붕이 워드마크</title>
          <desc id="desc">루프 심볼과 붕붕이 이름을 함께 배치한 로고. 글자는 벡터 윤곽선으로 포함되어 있습니다.</desc>
          <path fill="#292B27" fill-rule="evenodd" d="\(svgPath(wordmark))"/>
        </svg>
        """
        try Data((wordSVG + "\n").utf8).write(to: directory.appendingPathComponent("wordmark.svg"), options: .atomic)
        let preview = bitmap(width: 1440, height: 800) { c in
            c.setFillColor(color(0xF5F5F1).cgColor); c.fill(CGRect(x: 0, y: 0, width: 1440, height: 800))
            drawIcon(c, in: CGRect(x: 180, y: 230, width: 340, height: 340))
            c.addPath(fitted(lettering(), in: CGRect(x: 625, y: 318, width: 520, height: 160)))
            c.setFillColor(color(ink).cgColor); c.fillPath()
        }
        try png(preview, to: directory.appendingPathComponent("brand-preview.png"))
        let sizes = bitmap(width: 1000, height: 420) { c in
            c.setFillColor(color(0xF5F5F1).cgColor); c.fill(CGRect(x: 0, y: 0, width: 1000, height: 420))
            c.setFillColor(color(tile).cgColor); c.fill(CGRect(x: 0, y: 210, width: 1000, height: 210))
            for (i, size) in [16, 24, 32, 48, 64, 96].enumerated() {
                let x = CGFloat(80 + i * 160), s = CGFloat(size)
                drawIcon(c, in: CGRect(x: x - s / 2, y: 90 - s / 2, width: s, height: s))
                c.addPath(BrandSymbol.fitted(in: CGRect(x: x - s / 2, y: 305 - s / 2, width: s, height: s)))
                c.setFillColor(color(light).cgColor); c.drawPath(using: .eoFill)
            }
        }
        try png(sizes, to: directory.appendingPathComponent("size-check.png"))
    }
}
