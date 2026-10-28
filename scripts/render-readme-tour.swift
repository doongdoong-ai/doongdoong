// Composes README GIF frames from unmodified app captures. Usage: compose SHOTS_DIR FRAMES_DIR
import AppKit
let shots = CommandLine.arguments[1], out = CommandLine.arguments[2]
let W: CGFloat = 1600, H: CGFloat = 1000, fps = 15.0
struct Scene { let image: String; let eyebrow: String; let title: String; let body: String; let hold: Double; var swap: String? = nil }
let scenes = [
    Scene(image: "recording", eyebrow: "녹음", title: "강의를 녹음하면서 필기까지", body: "녹음 화면 옆에서 바로 마크다운 필기를 남깁니다.", hold: 2.6),
    Scene(image: "polishing", eyebrow: "정리", title: "녹음이 끝나면 AI가 정리합니다", body: "Mac에서 음성 인식 → 전체 맥락으로 교정 → 핵심 요약", hold: 2.6),
    Scene(image: "summary", eyebrow: "핵심 요약", title: "교수님이 강조한 내용을 카드로", body: "카드에서 원래 설명으로 바로 돌아가 다시 듣습니다.", hold: 2.6),
    Scene(image: "reading", eyebrow: "복습", title: "글과 음성을 함께 읽습니다", body: "문장을 누르면 그 부분부터 재생됩니다.", hold: 2.6),
    Scene(image: "vendor-codex", eyebrow: "AI 연결", title: "Codex든 Claude든, 쓰던 구독 그대로", body: "API 키 없이 로그인한 계정으로 교정·요약합니다.", hold: 3.6, swap: "vendor-claude"),
]
func load(_ n: String) -> NSImage { NSImage(contentsOfFile: "\(shots)/\(n).png")! }
func ease(_ t: Double) -> Double { let t = min(max(t, 0), 1); return t < 0.5 ? 4*t*t*t : 1 - pow(-2*t+2, 3)/2 }
let paper = NSColor(calibratedRed: 0.925, green: 0.922, blue: 0.898, alpha: 1)
let ink = NSColor(calibratedRed: 0.13, green: 0.13, blue: 0.12, alpha: 1)
let soft = NSColor(calibratedRed: 0.42, green: 0.41, blue: 0.38, alpha: 1)
let accent = NSColor(calibratedRed: 0.80, green: 0.36, blue: 0.27, alpha: 1)

func cardRect(_ img: NSImage) -> NSRect {
    let area = NSRect(x: 90, y: 40, width: W - 180, height: 700)
    let s = min(area.width / img.size.width, area.height / img.size.height)
    let w = img.size.width * s, h = img.size.height * s
    return NSRect(x: area.midX - w/2, y: area.minY, width: w, height: h)
}
func drawCard(_ img: NSImage, alpha: CGFloat, dy: CGFloat) {
    var r = cardRect(img); r.origin.y -= dy
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.16 * alpha); sh.shadowBlurRadius = 40; sh.shadowOffset = NSSize(width: 0, height: -14); sh.set()
    NSColor.white.withAlphaComponent(alpha).setFill(); NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14).addClip()
    img.draw(in: r, from: .zero, operation: .sourceOver, fraction: alpha)
    NSGraphicsContext.restoreGraphicsState()
    NSColor.black.withAlphaComponent(0.08 * alpha).setStroke()
    let border = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14); border.lineWidth = 1; border.stroke()
}
func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, y: CGFloat, alpha: CGFloat, kern: CGFloat = 0) {
    let p = NSMutableParagraphStyle(); p.alignment = .center
    let a = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color.withAlphaComponent(alpha), .paragraphStyle: p, .kern: kern])
    a.draw(in: NSRect(x: 0, y: y, width: W, height: size * 1.5))
}
func drawCaption(_ sc: Scene, index: Int, alpha: CGFloat, dy: CGFloat) {
    text(sc.eyebrow, size: 20, weight: .semibold, color: accent, y: 902 + dy, alpha: alpha, kern: 1)
    text(sc.title, size: 44, weight: .bold, color: ink, y: 830 + dy, alpha: alpha, kern: -0.5)
    text(sc.body, size: 21, weight: .regular, color: soft, y: 790 + dy, alpha: alpha)
}
func drawProgress(_ position: Double) {
    let n = scenes.count, dot: CGFloat = 8, gap: CGFloat = 10, wide: CGFloat = 30
    var x = W/2 - (CGFloat(n - 1) * (dot + gap) + wide) / 2
    for i in 0..<n {
        let w = dot + (wide - dot) * CGFloat(max(0, 1 - abs(position - Double(i))))
        (i == Int(position.rounded()) ? ink : ink.withAlphaComponent(0.2)).setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: 966, width: w, height: dot), xRadius: 4, yRadius: 4).fill()
        x += w + gap
    }
}
func drawCursor(at p: NSPoint, pressed: Bool) {
    let s: CGFloat = pressed ? 0.88 : 1
    let path = NSBezierPath()
    let pts: [(CGFloat, CGFloat)] = [(0,0),(0,-34),(9,-26),(15,-40),(21,-37),(15,-24),(27,-24)]
    for (i, q) in pts.enumerated() { let pt = NSPoint(x: p.x + q.0 * s, y: p.y + q.1 * s); i == 0 ? path.move(to: pt) : path.line(to: pt) }
    path.close()
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.3); sh.shadowBlurRadius = 6; sh.shadowOffset = NSSize(width: 0, height: -2); sh.set()
    NSColor.black.setFill(); path.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.setStroke(); path.lineWidth = 2.2; path.lineJoinStyle = .round; path.stroke()
}

let transition = 0.55
var frame = 0
func render(_ draw: () -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let g = NSGradient(starting: NSColor(calibratedRed: 0.955, green: 0.952, blue: 0.935, alpha: 1), ending: paper)!
    g.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: String(format: "%@/f%04d.png", out, frame)))
    frame += 1
}
for (i, sc) in scenes.enumerated() {
    let img = load(sc.image), next = i + 1 < scenes.count ? scenes[i + 1] : scenes[0]
    let holdFrames = Int(sc.hold * fps)
    for f in 0..<holdFrames {
        let t = Double(f) / fps
        render {
            var shown = img
            if let swap = sc.swap {
                let claude = load(swap), r = cardRect(img)
                let target = NSPoint(x: r.minX + r.width * 0.86, y: r.maxY - r.height * 0.19)
                let start = NSPoint(x: r.minX + r.width * 0.52, y: r.minY + r.height * 0.45)
                let move = ease((t - 0.4) / 1.0), clickAt = 1.5, k = t >= clickAt ? ease((t - clickAt) / 0.25) : 0
                drawCard(img, alpha: 1, dy: 0)
                if k > 0 { drawCard(claude, alpha: CGFloat(k), dy: 0) }
                shown = claude
                drawCaption(sc, index: i, alpha: 1, dy: 0)
                drawProgress(Double(i))
                let p = NSPoint(x: start.x + (target.x - start.x) * move, y: start.y + (target.y - start.y) * move)
                if t > clickAt - 0.05 && t < clickAt + 0.45 {
                    let r2 = CGFloat(ease((t - clickAt + 0.05) / 0.5))
                    accent.withAlphaComponent(0.35 * (1 - r2)).setFill()
                    NSBezierPath(ovalIn: NSRect(x: p.x - 10 - 26*r2, y: p.y - 10 - 26*r2, width: 20 + 52*r2, height: 20 + 52*r2)).fill()
                }
                drawCursor(at: p, pressed: abs(t - clickAt) < 0.12)
                _ = shown
            } else {
                drawCard(img, alpha: 1, dy: 0); drawCaption(sc, index: i, alpha: 1, dy: 0); drawProgress(Double(i))
            }
        }
    }
    let from = sc.swap.map(load) ?? img, to = load(next.image)
    for f in 0..<Int(transition * fps) {
        let k = ease(Double(f + 1) / (transition * fps))
        render {
            drawCard(from, alpha: 1, dy: 0)
            drawCard(to, alpha: CGFloat(k), dy: CGFloat(18 * (1 - k)))
            let out = ease(k * 2), into = ease(k * 2 - 1)
            if out < 1 { drawCaption(sc, index: i, alpha: CGFloat(1 - out), dy: CGFloat(8 * out)) }
            if into > 0 { drawCaption(next, index: i + 1, alpha: CGFloat(into), dy: CGFloat(-8 * (1 - into))) }
            drawProgress(Double(i) + k * (i + 1 < scenes.count ? 1 : -Double(i)))
        }
    }
}
print("frames=\(frame)")
