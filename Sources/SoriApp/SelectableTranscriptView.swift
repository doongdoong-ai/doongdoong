import AppKit
import SwiftUI
import SoriCore

/// One native text document allows selections to cross sentence boundaries.
struct TranscriptDocument {
    struct Entry {
        let segment: TranscriptSegment
        let range: NSRange
        let textRange: NSRange
    }
    let text: NSAttributedString
    let entries: [Entry]
    let matches: [NSRange]

    init(segments: [TranscriptSegment], original: Bool, size: CGFloat, query: String) {
        let output = NSMutableAttributedString()
        var entries: [Entry] = [], matches: [NSRange] = []
        for segment in segments {
            let start = output.length
            let timeStyle = NSMutableParagraphStyle()
            timeStyle.paragraphSpacing = 8
            output.append(NSAttributedString(string: (segment.hasReliableTiming ? "" : "약 ") + TimeText.clock(segment.start) + "\n", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: timeStyle,
                .link: URL(string: "doongdoong://sentence/\(segment.id)")!,
                .toolTip: segment.hasReliableTiming ? "이 문장 재생" : "정확한 위치를 확인하지 못했습니다. 가까운 음성부터 재생합니다."
            ]))
            let text = original ? segment.originalText : segment.text
            let textStart = output.length
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 7
            paragraph.lineBreakStrategy = .hangulWordPriority
            paragraph.paragraphSpacing = 26
            output.append(NSAttributedString(string: text + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: size),
                .foregroundColor: NSColor(SoriTheme.ink), .paragraphStyle: paragraph
            ]))
            let textRange = NSRange(location: textStart, length: (text as NSString).length)
            entries.append(.init(segment: segment, range: NSRange(location: start, length: output.length - start), textRange: textRange))
            if !query.isEmpty {
                let source = text as NSString
                var remaining = NSRange(location: 0, length: source.length)
                while remaining.length > 0 {
                    let match = source.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: remaining)
                    guard match.location != NSNotFound, match.length > 0 else { break }
                    matches.append(NSRange(location: textStart + match.location, length: match.length))
                    remaining = NSRange(location: NSMaxRange(match), length: source.length - NSMaxRange(match))
                }
            }
        }
        self.text = output; self.entries = entries; self.matches = matches
    }
}

struct SelectableTranscriptView: NSViewRepresentable {
    let recordingID: UUID
    let segments: [TranscriptSegment]
    let original: Bool
    let textSize: Double
    let query: String
    let selectedSearchID: Int?
    let activeID: Int?
    let playbackTime: Double
    let followPlayback: Bool
    let scrollRequest: Int
    let searchScrollRequest: Int
    let canPlay: Bool
    let canEdit: Bool
    let play: (TranscriptSegment) -> Void
    let togglePlayback: () -> Void
    let isLooping: (TranscriptSegment) -> Bool
    let isBookmarked: (TranscriptSegment) -> Bool
    let edit: (TranscriptSegment) -> Void
    let repeatSegment: (TranscriptSegment) -> Void
    let bookmark: (TranscriptSegment) -> Void
    let copy: (TranscriptSegment) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> TranscriptScrollView {
        makeScrollView(coordinator: context.coordinator)
    }

    func makeScrollView(coordinator: Coordinator) -> TranscriptScrollView {
        let scroll = TranscriptScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        let text = TranscriptTextView(frame: scroll.bounds)
        text.isEditable = false; text.isSelectable = true
        text.isRichText = true; text.drawsBackground = false
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.heightTracksTextView = false
        text.textContainer?.containerSize.height = .greatestFiniteMagnitude
        text.textContainer?.lineFragmentPadding = 0
        text.textContainerInset = NSSize(width: 38, height: 30)
        text.linkTextAttributes = [.foregroundColor: NSColor.secondaryLabelColor, .underlineStyle: 0]
        text.setAccessibilityLabel("전사문")
        text.setAccessibilityHelp("문장을 클릭하면 해당 구간부터 재생합니다. 드래그하여 본문을 선택하고 복사할 수 있습니다. 문장 메뉴는 마우스 오른쪽 버튼으로 엽니다.")
        text.delegate = coordinator
        scroll.documentView = text
        coordinator.textView = text
        return scroll
    }

    func updateNSView(_ scroll: TranscriptScrollView, context: Context) {
        context.coordinator.update(self, scroll: scroll)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SelectableTranscriptView
        weak var textView: TranscriptTextView?
        var document: TranscriptDocument?
        private var previous: SelectableTranscriptView?

        init(_ parent: SelectableTranscriptView) { self.parent = parent }

        func update(_ value: SelectableTranscriptView, scroll: TranscriptScrollView) {
            parent = value
            guard let textView else { return }
            let changedRecording = previous?.recordingID != value.recordingID
            let contentChanged = changedRecording || previous?.segments != value.segments || previous?.original != value.original
            let rebuilt = contentChanged || previous?.textSize != value.textSize || previous?.query != value.query
            if changedRecording { scroll.followPaused = false }
            if rebuilt {
                let selection = textView.selectedRanges
                let origin = scroll.contentView.bounds.origin
                let document = TranscriptDocument(segments: value.segments, original: value.original,
                                                  size: value.textSize, query: value.query)
                self.document = document
                textView.textStorage?.setAttributedString(document.text)
                if contentChanged { textView.setSelectedRange(NSRange(location: 0, length: 0)) }
                else {
                    let valid = selection.filter { NSMaxRange($0.rangeValue) <= document.text.length }
                    textView.selectedRanges = valid.isEmpty ? [NSValue(range: NSRange(location: 0, length: 0))] : valid
                    scroll.contentView.scroll(to: origin)
                }
            }
            textView.togglePlayback = value.canPlay ? value.togglePlayback : nil
            textView.playSentence = value.canPlay ? { [weak self] index in
                guard let self, let entry = self.document?.entries.first(where: {
                    NSLocationInRange(index, $0.textRange)
                }) else { return }
                self.parent.play(entry.segment)
            } : nil
            if rebuilt || previous?.canPlay != value.canPlay {
                textView.playableRanges = value.canPlay ? document?.entries.map(\.textRange) ?? [] : []
                textView.window?.invalidateCursorRects(for: textView)
            }
            textView.sentenceMenu = { [weak self] index in self?.menu(at: index) ?? [] }
            if rebuilt || previous?.activeID != value.activeID || previous?.selectedSearchID != value.selectedSearchID {
                applyHighlights()
            }
            let requestedPlayback = previous?.scrollRequest != value.scrollRequest
            let requestedSearch = !value.query.isEmpty && (rebuilt || previous?.selectedSearchID != value.selectedSearchID
                || previous?.searchScrollRequest != value.searchScrollRequest)
            if requestedPlayback || previous?.followPlayback == false && value.followPlayback { scroll.followPaused = false }
            let follows = value.followPlayback && value.activeID != nil && !scroll.followPaused && value.query.isEmpty && !textView.hasSelection && !textView.isSelecting
                && (changedRecording || previous?.activeID != value.activeID || previous?.followPlayback == false)
            if requestedSearch { reveal(value.selectedSearchID) }
            else if requestedPlayback || follows {
                reveal(value.activeID ?? value.segments.last(where: { $0.start <= value.playbackTime })?.id ?? value.segments.first?.id)
            }
            previous = value
        }

        private func applyHighlights() {
            guard let document, let storage = textView?.textStorage else { return }
            storage.beginEditing()
            storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: storage.length))
            if let active = document.entries.first(where: { $0.segment.id == parent.activeID }) {
                storage.addAttribute(.backgroundColor, value: NSColor(SoriTheme.accentSoft), range: active.textRange)
            }
            for match in document.matches {
                storage.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.24), range: match)
            }
            if !parent.query.isEmpty, let selected = document.entries.first(where: { $0.segment.id == parent.selectedSearchID }) {
                for match in document.matches where NSIntersectionRange(match, selected.textRange).length > 0 {
                    storage.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.5), range: match)
                }
            }
            storage.endEditing()
        }

        private func reveal(_ id: Int?) {
            guard let textView, let entry = document?.entries.first(where: { $0.segment.id == id }) else { return }
            textView.scrollRangeToVisible(entry.range)
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL, url.scheme == "doongdoong", url.host == "sentence",
                  let id = Int(url.lastPathComponent), let segment = parent.segments.first(where: { $0.id == id }) else { return false }
            if parent.canPlay { parent.play(segment) }
            return true
        }

        private func menu(at index: Int) -> [NSMenuItem] {
            guard let segment = document?.entries.first(where: { NSLocationInRange(index, $0.range) })?.segment else { return [] }
            return [
                item("이 문장 재생", enabled: parent.canPlay) { [parent] in parent.play(segment) },
                item(parent.isLooping(segment) ? "문장 반복 해제" : "이 문장 반복 듣기", enabled: parent.canPlay) { [parent] in parent.repeatSegment(segment) },
                item("문장 수정", enabled: parent.canEdit) { [parent] in parent.edit(segment) },
                item("문장 복사") { [parent] in parent.copy(segment) },
                item(parent.isBookmarked(segment) ? "북마크 보기" : "북마크 추가") { [parent] in parent.bookmark(segment) }
            ]
        }

        private func item(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> NSMenuItem {
            let item = TranscriptMenuItem(title: title, action: #selector(TranscriptMenuItem.invoke), keyEquivalent: "")
            item.target = item; item.handler = action; item.isEnabled = enabled
            return item
        }
    }
}

final class TranscriptMenuItem: NSMenuItem {
    var handler: (() -> Void)?
    @objc func invoke() { handler?() }
}

final class TranscriptTextView: NSTextView {
    var sentenceMenu: ((Int) -> [NSMenuItem])?
    var togglePlayback: (() -> Void)?
    var playSentence: ((Int) -> Void)?
    var playableRanges: [NSRange] = []
    private(set) var isSelecting = false
    var hasSelection: Bool { selectedRanges.contains { $0.rangeValue.length > 0 } }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           !hasSelection, let togglePlayback {
            togglePlayback()
        } else { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        isSelecting = true
        defer { isSelecting = false }
        guard let index = playableCharacterIndex(at: convert(event.locationInWindow, from: nil)),
              event.clickCount == 1,
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged],
                                          until: .distantFuture, inMode: .eventTracking, dequeue: true) else {
            super.mouseDown(with: event)
            return
        }
        if next.type == .leftMouseUp {
            window?.makeFirstResponder(self)
            setSelectedRange(NSRange(location: index, length: 0))
            playSentence?(index)
        } else {
            // Replay the first drag for AppKit's native selection loop. It owns
            // subsequent dragging, cross-sentence selection, and autoscrolling.
            NSApp.postEvent(next, atStart: true)
            super.mouseDown(with: event)
        }
    }

    /// Hit-test glyph bounds, not the nearest insertion point: margins and the
    /// space between paragraphs must not play an adjacent sentence.
    func playableCharacterIndex(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer, !playableRanges.isEmpty else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        layoutManager.ensureLayout(for: textContainer)
        let glyph = layoutManager.glyphIndex(for: local, in: textContainer)
        guard glyph < layoutManager.numberOfGlyphs,
              layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1),
                                         in: textContainer).contains(local) else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        return playableRanges.contains(where: { NSLocationInRange(index, $0) }) ? index : nil
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        for range in playableRanges {
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                                  in: textContainer) { rect, _ in
                let visible = rect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y).intersection(self.visibleRect)
                if !visible.isEmpty { self.addCursorRect(visible, cursor: .pointingHand) }
            }
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        if playableCharacterIndex(at: convert(event.locationInWindow, from: nil)) != nil {
            NSCursor.pointingHand.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        menu.autoenablesItems = false
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        let items = sentenceMenu?(index) ?? []
        if !items.isEmpty { menu.addItem(.separator()); items.forEach(menu.addItem) }
        return menu
    }
}

final class TranscriptScrollView: NSScrollView {
    var followPaused = false

    override func scrollWheel(with event: NSEvent) {
        if event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 { followPaused = true }
        super.scrollWheel(with: event)
    }

    override func layout() {
        super.layout()
        guard let text = documentView as? NSTextView else { return }
        let inset = NSSize(width: max(38, (contentSize.width - 720) / 2), height: 30)
        if text.textContainerInset != inset { text.textContainerInset = inset }
    }
}

/// Native selection for card text, including heading-to-summary selections.
struct SelectableCardText: NSViewRepresentable {
    let text: NSAttributedString

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.isEditable = false; view.isSelectable = true; view.isRichText = true
        view.drawsBackground = false; view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isHorizontallyResizable = false; view.isVerticallyResizable = true
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        guard view.attributedString() != text else { return }
        view.textStorage?.setAttributedString(text)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, let container = nsView.textContainer, let layout = nsView.layoutManager else { return nil }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
    }
}
