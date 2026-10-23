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

enum TranscriptScrollDestination: Equatable {
    case above, below
    var symbol: String { self == .above ? "arrow.up" : "arrow.down" }
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
    var playbackPositionChanged: (TranscriptScrollDestination?) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> TranscriptScrollView {
        makeScrollView(coordinator: context.coordinator)
    }

    func makeScrollView(coordinator: Coordinator) -> TranscriptScrollView {
        let scroll = TranscriptScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.focusRingType = .none
        // SwiftUI places this reader below its own header. AppKit must not add
        // late titlebar/ruler insets while a playback scroll is already moving.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = .init()
        scroll.contentView.automaticallyAdjustsContentInsets = false
        scroll.contentView.contentInsets = .init()
        let text = TranscriptTextView(frame: scroll.bounds)
        text.focusRingType = .none
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
        coordinator.observe(scroll)
        return scroll
    }

    func updateNSView(_ scroll: TranscriptScrollView, context: Context) {
        context.coordinator.update(self, scroll: scroll)
    }

    static func dismantleNSView(_ scroll: TranscriptScrollView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SelectableTranscriptView
        weak var textView: TranscriptTextView?
        var document: TranscriptDocument?
        private var previous: SelectableTranscriptView?
        private weak var scrollView: TranscriptScrollView?
        private var positionUpdatePending = false
        private var reportedPosition: TranscriptScrollDestination?
        private var highlightedPlaybackRange: NSRange?
        private var highlightedSearchRange: NSRange?

        init(_ parent: SelectableTranscriptView) { self.parent = parent }

        func observe(_ scroll: TranscriptScrollView) {
            scrollView = scroll
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged),
                name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            NotificationCenter.default.addObserver(self, selector: #selector(manualScrollStarted),
                name: NSScrollView.willStartLiveScrollNotification, object: scroll)
            scroll.viewportChanged = { [weak self] in self?.schedulePositionUpdate() }
            textView?.manualScroll = { [weak scroll] in scroll?.followPaused = true }
        }

        func stopObserving() {
            NotificationCenter.default.removeObserver(self)
            scrollView?.stopPlaybackScroll()
            scrollView?.viewportChanged = nil
            textView?.manualScroll = nil
            scrollView = nil
        }

        @objc private func viewportChanged() { schedulePositionUpdate() }
        @objc private func manualScrollStarted() { scrollView?.followPaused = true }

        // Bounds notifications also arrive during SwiftUI updates and text layout.
        // Coalesce them and publish only after the current update has finished.
        private func schedulePositionUpdate() {
            guard !positionUpdatePending else { return }
            positionUpdatePending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.positionUpdatePending = false
                guard self.scrollView != nil else { return }
                let position = self.playbackScrollDestination
                guard position != self.reportedPosition else { return }
                self.reportedPosition = position
                self.parent.playbackPositionChanged(position)
            }
        }

        private var playbackID: Int? {
            parent.activeID ?? parent.segments.last(where: { $0.start <= parent.playbackTime })?.id ?? parent.segments.first?.id
        }

        var playbackScrollDestination: TranscriptScrollDestination? {
            guard parent.canPlay, parent.query.isEmpty, let scrollView, !scrollView.isFollowingPlayback,
                  let rect = textRect(for: playbackID), scrollView.contentSize.height > 24 else { return nil }
            let viewport = scrollView.documentVisibleRect.insetBy(dx: 0, dy: 8)
            // A long sentence may span the viewport: a visible line is enough.
            if rect.intersection(viewport).height >= min(24, rect.height) { return nil }
            return rect.midY < viewport.midY ? .above : .below
        }

        private func textRect(for id: Int?) -> NSRect? {
            guard let textView, let entry = document?.entries.first(where: { $0.segment.id == id }),
                  let layout = textView.layoutManager, let container = textView.textContainer else { return nil }
            let range = entry.textRange.length > 0 ? entry.textRange : entry.range
            layout.ensureLayout(forCharacterRange: range)
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            return layout.boundingRect(forGlyphRange: glyphs, in: container)
                .offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
        }

        func update(_ value: SelectableTranscriptView, scroll: TranscriptScrollView) {
            parent = value
            guard let textView else { return }
            let changedRecording = previous?.recordingID != value.recordingID
            let contentChanged = changedRecording || previous?.segments != value.segments || previous?.original != value.original
            let rebuilt = contentChanged || previous?.textSize != value.textSize || previous?.query != value.query
            if rebuilt || !value.followPlayback || !value.query.isEmpty || !value.canPlay {
                scroll.stopPlaybackScroll()
            }
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
                // Resolve the viewport width/insets before the first follow scroll.
                scroll.layoutSubtreeIfNeeded()
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
                applyHighlights(rebuilt: rebuilt)
            }
            let requestedPlayback = previous?.scrollRequest != value.scrollRequest
            let requestedSearch = !value.query.isEmpty && (rebuilt || previous?.selectedSearchID != value.selectedSearchID
                || previous?.searchScrollRequest != value.searchScrollRequest)
            if requestedPlayback || previous?.followPlayback == false && value.followPlayback { scroll.followPaused = false }
            let follows = value.followPlayback && value.activeID != nil && !scroll.followPaused && value.query.isEmpty && !textView.hasSelection && !textView.isSelecting
                && (changedRecording || previous?.activeID != value.activeID || previous?.followPlayback == false)
            if requestedSearch { reveal(value.selectedSearchID) }
            else if requestedPlayback || follows {
                if requestedPlayback, previous != nil {
                    textView.setSelectedRange(NSRange(location: textView.selectedRange().location, length: 0))
                }
                reveal(playbackID, centered: true, animated: previous != nil && !changedRecording)
            }
            previous = value
            schedulePositionUpdate()
        }

        private func applyHighlights(rebuilt: Bool) {
            guard let document, let layout = textView?.layoutManager else { return }
            let active = document.entries.first(where: { $0.segment.id == parent.activeID })?.textRange
            let selected = parent.query.isEmpty ? nil
                : document.entries.first(where: { $0.segment.id == parent.selectedSearchID })?.textRange
            // Playback/search emphasis is display-only. Editing NSTextStorage
            // here invalidates layout throughout a long lecture on every sentence.
            let dirty = rebuilt ? [NSRange(location: 0, length: document.text.length)]
                : [highlightedPlaybackRange, active, highlightedSearchRange, selected].compactMap { $0 }
            for range in dirty where range.length > 0 {
                layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
                if let active {
                    let overlap = NSIntersectionRange(active, range)
                    if overlap.length > 0 {
                        layout.addTemporaryAttribute(.backgroundColor, value: NSColor(SoriTheme.accentSoft), forCharacterRange: overlap)
                    }
                }
                // Search takes precedence over playback, including when the
                // active sentence moves out of a selected search result.
                for match in document.matches {
                    let overlap = NSIntersectionRange(match, range)
                    guard overlap.length > 0 else { continue }
                    let isSelected = selected.map { NSIntersectionRange(match, $0).length > 0 } ?? false
                    layout.addTemporaryAttribute(.backgroundColor,
                        value: NSColor.systemYellow.withAlphaComponent(isSelected ? 0.5 : 0.24), forCharacterRange: overlap)
                }
            }
            highlightedPlaybackRange = active
            highlightedSearchRange = selected
        }

        private func reveal(_ id: Int?, centered: Bool = false, animated: Bool = false) {
            guard let textView, let entry = document?.entries.first(where: { $0.segment.id == id }) else { return }
            guard centered, let scrollView, let rect = textRect(for: id) else {
                textView.scrollRangeToVisible(entry.range)
                return
            }
            let clip = scrollView.contentView
            let height = clip.bounds.height
            let desiredY = rect.height > height * 0.7 ? rect.minY - 24 : rect.midY - height * 0.4
            let y = max(0, min(desiredY, textView.bounds.height - height))
            let destination = NSPoint(x: clip.bounds.origin.x, y: y)
            scrollView.scrollToPlayback(destination, animated: animated && scrollView.window?.isVisible == true)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            if textView?.hasSelection == true { scrollView?.followPaused = true }
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
    var manualScroll: (() -> Void)?
    var playableRanges: [NSRange] = []
    private(set) var isSelecting = false
    var hasSelection: Bool { selectedRanges.contains { $0.rangeValue.length > 0 } }

    override func keyDown(with event: NSEvent) {
        if [115, 116, 119, 121].contains(event.keyCode) { manualScroll?() }
        if event.keyCode == 49, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           !hasSelection, let togglePlayback {
            togglePlayback()
        } else { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        manualScroll?()
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
        layoutManager.ensureLayout(forBoundingRect: NSRect(origin: local, size: NSSize(width: 1, height: 1)), in: textContainer)
        let glyph = layoutManager.glyphIndex(for: local, in: textContainer)
        guard glyph < layoutManager.numberOfGlyphs,
              layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1),
                                         in: textContainer).contains(local) else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        return playableRanges(intersecting: NSRange(location: index, length: 1)).isEmpty ? nil : index
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for rect in playableCursorRects { addCursorRect(rect, cursor: .pointingHand) }
    }

    // AppKit rebuilds cursor regions while scrolling. Limit both text layout
    // and line enumeration to the viewport, regardless of lecture length.
    var playableCursorRects: [NSRect] {
        guard !playableRanges.isEmpty, let layoutManager, let textContainer else { return [] }
        let viewport = visibleRect
        guard !viewport.isEmpty else { return [] }
        let origin = textContainerOrigin
        let local = viewport.offsetBy(dx: -origin.x, dy: -origin.y)
        layoutManager.ensureLayout(forBoundingRect: local, in: textContainer)
        let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: local, in: textContainer)
        guard visibleGlyphs.length > 0 else { return [] }
        let characters = layoutManager.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        var rects: [NSRect] = []
        for range in playableRanges(intersecting: characters) where range.length > 0 {
            let glyphs = layoutManager.glyphRange(forCharacterRange: NSIntersectionRange(range, characters), actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                                  in: textContainer) { rect, _ in
                let visible = rect.offsetBy(dx: origin.x, dy: origin.y).intersection(viewport)
                if !visible.isEmpty { rects.append(visible) }
            }
        }
        return rects
    }

    private func playableRanges(intersecting range: NSRange) -> ArraySlice<NSRange> {
        // Document entries are ordered and nonoverlapping, so skip offscreen
        // sentences with a binary search instead of walking the entire file.
        var lower = 0, upper = playableRanges.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if NSMaxRange(playableRanges[middle]) <= range.location { lower = middle + 1 }
            else { upper = middle }
        }
        var end = lower
        while end < playableRanges.count, playableRanges[end].location < NSMaxRange(range) { end += 1 }
        return playableRanges[lower..<end]
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
    var followPaused = false { didSet { if followPaused { stopPlaybackScroll() } } }
    var viewportChanged: (() -> Void)?
    private var playbackAnimation: TranscriptScrollAnimation?
    private var viewportSize: NSSize = .zero
    var isFollowingPlayback: Bool { playbackAnimation != nil }

    func scrollToPlayback(_ destination: NSPoint, animated: Bool) {
        stopPlaybackScroll()
        layoutSubtreeIfNeeded()
        let origin = contentView.bounds.origin
        guard animated, abs(destination.y - origin.y) > 1 else {
            contentView.scroll(to: destination)
            reflectScrolledClipView(contentView)
            return
        }
        // Use an owned AppKit animation so a wheel gesture, scrollbar drag or
        // text selection can stop it immediately at the currently visible point.
        let distance = abs(destination.y - origin.y) / max(1, contentSize.height)
        let animation = TranscriptScrollAnimation(duration: 0.38 + min(0.22, Double(distance) * 0.12), animationCurve: .easeInOut)
        animation.animationBlockingMode = .nonblocking
        animation.frameRate = 60
        animation.update = { [weak self] fraction in
            guard let self else { return }
            self.contentView.scroll(to: NSPoint(x: origin.x + (destination.x - origin.x) * fraction,
                                               y: origin.y + (destination.y - origin.y) * fraction))
            self.reflectScrolledClipView(self.contentView)
        }
        animation.finished = { [weak self] in
            self?.playbackAnimation = nil
            self?.viewportChanged?()
        }
        playbackAnimation = animation
        animation.start()
        viewportChanged?()
    }

    func stopPlaybackScroll() {
        guard let animation = playbackAnimation else { return }
        playbackAnimation = nil
        animation.update = nil; animation.finished = nil
        animation.stop()
        viewportChanged?()
    }

    override func scrollWheel(with event: NSEvent) {
        if event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 { followPaused = true }
        super.scrollWheel(with: event)
    }

    override func layout() {
        super.layout()
        if viewportSize != contentSize { stopPlaybackScroll(); viewportSize = contentSize }
        guard let text = documentView as? NSTextView else { return }
        let inset = NSSize(width: max(38, (contentSize.width - 720) / 2), height: 30)
        if text.textContainerInset != inset { text.textContainerInset = inset }
        viewportChanged?()
    }
}

private final class TranscriptScrollAnimation: NSAnimation {
    var update: ((CGFloat) -> Void)?
    var finished: (() -> Void)?
    override var currentProgress: NSAnimation.Progress {
        didSet {
            update?(CGFloat(currentValue))
            if currentProgress >= 1 { finished?() }
        }
    }
}

/// Native selection for card text, including heading-to-summary selections.
struct SelectableCardText: NSViewRepresentable {
    let text: NSAttributedString

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.focusRingType = .none
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
