import AppKit

/// Presentation only: every UTF-16 character and source range remains intact.
/// Foundation's CommonMark parser identifies content; TextKit hides its delimiters.
@MainActor struct LiveMarkdownDocument {
    struct Marker {
        enum Kind { case bullet, task(Bool), quote, rule }
        let kind: Kind
        let line: NSRange
        let content: Int
        let prefix: NSRange
        let indent: CGFloat
        var taskIndex: Int?
    }
    struct CodeBlock { let range: NSRange; let fences: [NSRange] }
    let source: String
    let styled: NSAttributedString
    let syntax: IndexSet
    let markers: [Marker]
    let codeBlocks: [CodeBlock]

    init(_ source: String) {
        self.source = source
        let ns = source as NSString
        let styled = NSMutableAttributedString(string: source, attributes: MarkdownStyle.body)
        var visible = IndexSet(), candidates = IndexSet(), codeRanges = IndexSet()
        var markers: [Int: Marker] = [:], codeBlocks: [CodeBlock] = []
        let parsed = try? AttributedString(markdown: source, options: .init(
            interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible, appliesSourcePositionAttributes: true))
        if let parsed {
            for run in parsed.runs {
                guard let position = run.markdownSourcePosition, let stringRange = Range(position, in: source) else { continue }
                // Convert through String.Index so composed Unicode characters use
                // their full UTF-16 span, including surrogate pairs and joiners.
                let range = NSRange(stringRange, in: source)
                guard range.length > 0, NSMaxRange(range) <= ns.length else { continue }
                let components = run.presentationIntent?.components ?? []
                let inline = run.inlinePresentationIntent ?? []
                var heading = 0, depth = 0, quote = false, code = false, ordered = false, table = false
                for component in components {
                    switch component.kind {
                    case .header(let level): heading = level
                    case .unorderedList: depth += 1
                    case .orderedList: if depth == 0 { ordered = true }; depth += 1
                    case .blockQuote: quote = true
                    case .codeBlock: code = true
                    case .table: table = true
                    default: break
                    }
                }
                if code {
                    // Fenced content is never interpreted as inline Markdown.
                    let full = ns.lineRange(for: range)
                    codeRanges.insert(integersIn: full.location..<NSMaxRange(full))
                    let fences = Self.matches(#"(?m)^ {0,3}(`{3,}|~{3,})[^\n\r]*"#, in: source, range: full).map(\.range)
                    codeBlocks.append(.init(range: full, fences: fences))
                    styled.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)], range: full)
                    continue
                }
                // Tables remain editable source instead of losing their separators.
                // Source preservation takes precedence over a partial table renderer.
                if table { continue }
                visible.insert(integersIn: range.location..<NSMaxRange(range))
                let lines = ns.lineRange(for: range)
                candidates.insert(integersIn: lines.location..<NSMaxRange(lines))
                let size: CGFloat = heading == 1 ? 28 : heading == 2 ? 23 : heading > 0 ? 19 : 16
                let weight: NSFont.Weight = heading > 0 || inline.contains(.stronglyEmphasized) ? .semibold : .regular
                var font = NSFont.systemFont(ofSize: size, weight: weight)
                if inline.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                if inline.contains(.code) { font = .monospacedSystemFont(ofSize: 14, weight: .regular) }
                if heading > 0 { styled.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: .semibold), range: lines) }
                styled.addAttribute(.font, value: font, range: range)
                if quote { styled.addAttribute(.foregroundColor, value: NSColor(SoriTheme.secondary), range: lines) }
                if inline.contains(.code) {
                    styled.addAttribute(.backgroundColor, value: NSColor(SoriTheme.sidebar), range: range)
                    codeRanges.insert(integersIn: range.location..<NSMaxRange(range))
                }
                if inline.contains(.strikethrough) { styled.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
                if let link = run.link, ["https", "http", "mailto"].contains(link.scheme?.lowercased() ?? "") {
                    styled.addAttributes([.foregroundColor: NSColor(SoriTheme.green), .underlineStyle: NSUnderlineStyle.single.rawValue,
                                          .toolTip: "⌘클릭하여 열기 · \(link.absoluteString)", .markdownURL: link], range: range)
                }
                let line = ns.lineRange(for: NSRange(location: range.location, length: 0))
                if depth > 0, markers[line.location] == nil,
                   let match = Self.matches(#"^([ \t]*(?:> ?)*[ \t]*)([-+*]|\d+[.)]) ([\s\S]*)$"#,
                                            in: source, range: Self.contentRange(line, in: ns)).first {
                    let prefix = NSRange(location: line.location, length: match.range(at: 3).location - line.location)
                    let content = NSMaxRange(prefix)
                    let task = Self.matches(#"^\[([ xX])\] "#, in: source,
                                            range: NSRange(location: content, length: NSMaxRange(Self.contentRange(line, in: ns)) - content)).first
                    if let task {
                        visible.remove(integersIn: task.range.location..<NSMaxRange(task.range))
                        let checked = ns.substring(with: task.range(at: 1)).lowercased() == "x"
                        markers[line.location] = .init(kind: .task(checked), line: line, content: NSMaxRange(task.range),
                            prefix: NSRange(location: line.location, length: NSMaxRange(task.range) - line.location),
                            indent: CGFloat(depth) * 24 + (quote ? 18 : 0), taskIndex: task.range(at: 1).location)
                        if checked {
                            let body = NSRange(location: NSMaxRange(task.range), length: NSMaxRange(Self.contentRange(line, in: ns)) - NSMaxRange(task.range))
                            styled.addAttributes([.foregroundColor: NSColor(SoriTheme.secondary), .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: body)
                        }
                    } else if !ordered {
                        markers[line.location] = .init(kind: .bullet, line: line, content: content, prefix: prefix, indent: CGFloat(depth) * 24 + (quote ? 18 : 0))
                    } else {
                        // Keep the actual number visible; only inline delimiters fold.
                        visible.insert(integersIn: prefix.location..<NSMaxRange(prefix))
                    }
                } else if quote, markers[line.location] == nil {
                    let prefix = NSRange(location: line.location, length: range.location - line.location)
                    markers[line.location] = .init(kind: .quote, line: line, content: range.location, prefix: prefix, indent: 20)
                }
            }
        }
        var hidden = candidates.subtracting(visible).subtracting(codeRanges)
        for match in Self.matches(#"\\([\\`*{}\[\]()#+\-.!_>~|])"#, in: source) {
            guard !codeRanges.contains(match.range.location) else { continue }
            hidden.insert(match.range.location)
        }
        // Newlines always retain their real source positions and line geometry.
        for i in hidden where ns.character(at: i) == 10 || ns.character(at: i) == 13 { hidden.remove(i) }
        for block in codeBlocks { for fence in block.fences { hidden.insert(integersIn: fence.location..<NSMaxRange(fence)) } }
        // Obsidian-style highlights, which aren't part of CommonMark.
        for match in Self.matches(#"(?<![\\=])==([^=\n]+)==(?!\=)"#, in: source) {
            guard !codeRanges.intersects(integersIn: match.range.location..<NSMaxRange(match.range)) else { continue }
            styled.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.22), range: match.range(at: 1))
            hidden.insert(integersIn: match.range.location..<(match.range.location + 2))
            hidden.insert(integersIn: (NSMaxRange(match.range) - 2)..<NSMaxRange(match.range))
        }
        for match in Self.matches(#"(?m)^ {0,3}(?:\* ?\* ?\*[ *]*|- ?- ?-[ -]*|_ ?_ ?_[ _]*)$"#, in: source) {
            guard !codeRanges.intersects(integersIn: match.range.location..<NSMaxRange(match.range)) else { continue }
            hidden.insert(integersIn: match.range.location..<NSMaxRange(match.range))
            let line = ns.lineRange(for: match.range)
            markers[line.location] = .init(kind: .rule, line: line, content: line.location, prefix: match.range, indent: 0)
        }
        self.styled = styled; syntax = hidden
        self.markers = markers.values.sorted { $0.line.location < $1.line.location }
        self.codeBlocks = codeBlocks
    }

    func presentation(selection: NSRange?) -> (text: NSAttributedString, hidden: IndexSet, markers: [Marker]) {
        let ns = source as NSString
        var hidden = syntax
        let active: NSRange?
        if let selection, selection.location <= ns.length {
            active = ns.lineRange(for: NSRange(location: selection.location, length: min(selection.length, ns.length - selection.location)))
        } else { active = nil }
        if let active { hidden.remove(integersIn: active.location..<NSMaxRange(active)) }
        for block in codeBlocks where active.map({ NSIntersectionRange($0, block.range).length > 0 }) == true {
            for fence in block.fences { hidden.remove(integersIn: fence.location..<NSMaxRange(fence)) }
        }
        let output = NSMutableAttributedString(attributedString: styled)
        var decorations: [Marker] = []
        for marker in markers {
            let editing = active.map { NSIntersectionRange($0, marker.line).length > 0 } ?? false
            let paragraph = (MarkdownStyle.body[.paragraphStyle] as! NSParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
            paragraph.headIndent = marker.indent
            paragraph.firstLineHeadIndent = editing ? max(0, marker.indent - 24) : marker.indent
            output.addAttribute(.paragraphStyle, value: paragraph, range: marker.line)
            if !editing { decorations.append(marker) }
        }
        // A subdued delimiter is still fully editable on the active line.
        if let active {
            for range in syntax.intersection(IndexSet(integersIn: active.location..<NSMaxRange(active))).rangeView {
                output.addAttribute(.foregroundColor, value: NSColor(SoriTheme.secondary), range: NSRange(range))
            }
        }
        return (output, hidden, decorations)
    }

    private static func contentRange(_ line: NSRange, in text: NSString) -> NSRange {
        var end = NSMaxRange(line)
        while end > line.location, [10, 13].contains(text.character(at: end - 1)) { end -= 1 }
        return NSRange(location: line.location, length: end - line.location)
    }

    private static func matches(_ pattern: String, in text: String, range: NSRange? = nil) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: range ?? NSRange(location: 0, length: (text as NSString).length))
    }
}

extension NSAttributedString.Key {
    static let markdownURL = NSAttributedString.Key("DoongdoongMarkdownURL")
}

@MainActor final class LiveMarkdownLayoutManager: NSLayoutManager, @preconcurrency NSLayoutManagerDelegate {
    var hidden = IndexSet()
    var markers: [LiveMarkdownDocument.Marker] = []
    var codeBlocks: [LiveMarkdownDocument.CodeBlock] = []

    override init() { super.init(); backgroundLayoutEnabled = false; delegate = self }
    required init?(coder: NSCoder) { super.init(coder: coder); backgroundLayoutEnabled = false; delegate = self }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>,
                       font: NSFont, forGlyphRange range: NSRange) -> Int {
        var properties = Array(UnsafeBufferPointer(start: props, count: range.length))
        var changed = false
        for index in 0..<range.length where hidden.contains(characterIndexes[index]) {
            properties[index].insert(.null); changed = true
        }
        guard changed else { return 0 }
        setGlyphs(glyphs, properties: properties, characterIndexes: characterIndexes, font: font, forGlyphRange: range)
        return range.length
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let container = textContainers.first else { super.drawBackground(forGlyphRange: glyphsToShow, at: origin); return }
        for block in codeBlocks {
            let glyphs = glyphRange(forCharacterRange: block.range, actualCharacterRange: nil)
            guard NSIntersectionRange(glyphs, glyphsToShow).length > 0 else { continue }
            var rect = boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x = origin.x; rect.origin.y += origin.y - 3
            rect.size.width = container.size.width; rect.size.height += 6
            NSColor(SoriTheme.sidebar).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    func markerRect(_ marker: LiveMarkdownDocument.Marker, origin: NSPoint) -> NSRect {
        guard let storage = textStorage, storage.length > 0 else { return .zero }
        let index = glyphIndexForCharacter(at: min(marker.content, storage.length - 1))
        let line = lineFragmentRect(forGlyphAt: index, effectiveRange: nil)
        return NSRect(x: origin.x + marker.indent - 21, y: origin.y + line.minY + (line.height - 14) / 2, width: 14, height: 14)
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        for marker in markers {
            let glyphs = glyphRange(forCharacterRange: marker.line, actualCharacterRange: nil)
            guard NSIntersectionRange(glyphs, glyphsToShow).length > 0 else { continue }
            let rect = markerRect(marker, origin: origin)
            switch marker.kind {
            case .bullet:
                NSColor(SoriTheme.secondary).setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.midX - 2.3, y: rect.midY - 2.3, width: 4.6, height: 4.6)).fill()
            case .task(let checked):
                let box = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 3, yRadius: 3)
                if checked {
                    NSColor(SoriTheme.ink).setFill(); box.fill()
                    NSColor.white.setStroke()
                    let tick = NSBezierPath(); tick.lineWidth = 1.5
                    tick.move(to: NSPoint(x: rect.minX + 3.5, y: rect.midY))
                    tick.line(to: NSPoint(x: rect.minX + 6, y: rect.maxY - 4))
                    tick.line(to: NSPoint(x: rect.maxX - 3, y: rect.minY + 4)); tick.stroke()
                } else { NSColor(SoriTheme.secondary).withAlphaComponent(0.6).setStroke(); box.lineWidth = 1.2; box.stroke() }
            case .quote:
                let start = lineFragmentRect(forGlyphAt: glyphIndexForCharacter(at: marker.content), effectiveRange: nil)
                var endIndex = NSMaxRange(marker.line) - 1
                let source = (textStorage?.string ?? "") as NSString
                while endIndex > marker.content, [10, 13].contains(source.character(at: endIndex)) { endIndex -= 1 }
                let end = lineFragmentRect(forGlyphAt: glyphIndexForCharacter(at: endIndex), effectiveRange: nil)
                NSColor(SoriTheme.faint).setFill()
                NSBezierPath(roundedRect: NSRect(x: origin.x + 2, y: origin.y + start.minY + 2, width: 3, height: max(20, end.maxY - start.minY - 4)), xRadius: 1.5, yRadius: 1.5).fill()
            case .rule:
                NSColor(SoriTheme.line).setFill()
                NSRect(x: origin.x, y: rect.midY, width: textContainers.first?.size.width ?? 100, height: 1).fill()
            }
        }
    }
}
