import AppKit
import SwiftUI

@MainActor final class MarkdownEditorController {
    weak var textView: MarkdownTextView?
    func perform(_ command: MarkdownCommand) { textView?.apply(command) }
    func endComposition() { textView?.unmarkText() }
    func find() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView); textView.markdownFind(nil)
    }
}

struct MarkdownNotesEditor: NSViewRepresentable {
    @Binding var text: String
    let controller: MarkdownEditorController

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView { makeScrollView(coordinator: context.coordinator) }

    func makeScrollView(coordinator: Coordinator) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay; scroll.drawsBackground = false
        scroll.focusRingType = .none; scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = .init(); scroll.contentView.automaticallyAdjustsContentInsets = false
        scroll.contentView.contentInsets = .init()
        let storage = NSTextStorage()
        let layout = LiveMarkdownLayoutManager()
        let container = NSTextContainer(size: NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        let editor = MarkdownTextView(frame: scroll.bounds, textContainer: container)
        editor.isEditable = true; editor.isSelectable = true; editor.isRichText = false
        editor.drawsBackground = false; editor.focusRingType = .none; editor.allowsUndo = true
        editor.font = .systemFont(ofSize: 16); editor.textColor = NSColor(SoriTheme.ink)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        container.widthTracksTextView = true; container.heightTracksTextView = false
        container.lineFragmentPadding = 0
        editor.textContainerInset = NSSize(width: 8, height: 22)
        editor.insertionPointColor = NSColor(SoriTheme.ink)
        editor.selectedTextAttributes = [.backgroundColor: NSColor(SoriTheme.ink).withAlphaComponent(0.12)]
        editor.typingAttributes = MarkdownStyle.body
        editor.usesFindBar = true; editor.isIncrementalSearchingEnabled = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false; editor.isGrammarCheckingEnabled = false
        editor.setAccessibilityLabel("수업 필기")
        editor.setAccessibilityHelp("마크다운 라이브 편집기. 클릭하면 바로 수정합니다. 커서가 있는 줄의 문법 기호가 표시됩니다. 체크박스는 클릭하여 완료할 수 있습니다.")
        editor.string = text; editor.highlight()
        editor.delegate = coordinator
        scroll.documentView = editor; controller.textView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) { context.coordinator.update(self, scroll: scroll) }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownNotesEditor
        init(_ parent: MarkdownNotesEditor) { self.parent = parent }
        func update(_ parent: MarkdownNotesEditor, scroll: NSScrollView) {
            self.parent = parent
            guard let editor = scroll.documentView as? MarkdownTextView else { return }
            parent.controller.textView = editor
            if editor.string != parent.text, !editor.hasMarkedText() {
                let selection = editor.selectedRange()
                editor.string = parent.text
                editor.setSelectedRange(NSRange(location: min(selection.location, (parent.text as NSString).length), length: 0))
                editor.highlight()
            }
        }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? MarkdownTextView else { return }
            parent.text = editor.string; editor.scheduleHighlight(); editor.needsDisplay = true
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            (notification.object as? MarkdownTextView)?.highlight()
        }
    }
}

final class MarkdownTextView: NSTextView {
    private var highlightTask: Task<Void, Never>?
    private var document: LiveMarkdownDocument?
    private var revealedLine: NSRange?
    private var rendering = false
    private var trackingSelection = false
    private var editingFocused = false

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { editingFocused = true; highlight() }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { editingFocused = false; highlight() }
        return accepted
    }
    override func unmarkText() { super.unmarkText(); scheduleHighlight() }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let layout = layoutManager as? LiveMarkdownLayoutManager {
            for marker in layout.markers where marker.taskIndex != nil {
                if layout.markerRect(marker, origin: textContainerOrigin).insetBy(dx: -4, dy: -4).contains(point),
                   let index = marker.taskIndex {
                    toggleTask(at: index); return
                }
            }
        }
        if event.modifierFlags.contains(.command), !string.isEmpty {
            let index = min(characterIndexForInsertion(at: point), (string as NSString).length - 1)
            if let url = textStorage?.attribute(.markdownURL, at: index, effectiveRange: nil) as? URL {
                NSWorkspace.shared.open(url); return
            }
        }
        // Keep the hit-tested geometry fixed throughout a click or drag. Reveal
        // delimiters only after AppKit has resolved the original source selection.
        trackingSelection = true
        super.mouseDown(with: event)
        trackingSelection = false; highlight()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let layout = layoutManager as? LiveMarkdownLayoutManager else { return }
        for marker in layout.markers where marker.taskIndex != nil {
            addCursorRect(layout.markerRect(marker, origin: textContainerOrigin).insetBy(dx: -4, dy: -4), cursor: .pointingHand)
        }
    }

    func toggleTask(at index: Int) {
        if hasMarkedText() { unmarkText() }
        let source = string as NSString
        guard index > 0, index + 1 < source.length, source.character(at: index - 1) == 91,
              source.character(at: index + 1) == 93, [32, 88, 120].contains(source.character(at: index)) else { return }
        let selection = selectedRange()
        apply(.init(range: NSRange(location: index, length: 1), replacement: source.character(at: index) == 32 ? "x" : " ", selection: selection))
    }

    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }
    override func copy(_ sender: Any?) {
        guard selectedRange().length == 0 else { super.copy(sender); return }
        let source = string as NSString, line = (string as NSString).lineRange(for: selectedRange())
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(source.substring(with: line), forType: .string)
    }
    override func cut(_ sender: Any?) {
        guard selectedRange().length == 0 else { super.cut(sender); return }
        copy(sender)
        let line = (string as NSString).lineRange(for: selectedRange())
        apply(.init(range: line, replacement: "", selection: NSRange(location: line.location, length: 0)))
    }
    override func insertNewline(_ sender: Any?) {
        guard !hasMarkedText(), let edit = MarkdownEditing.newline(text: string, selection: selectedRange()) else {
            super.insertNewline(sender); return
        }
        apply(edit)
    }
    override func insertLineBreak(_ sender: Any?) { insertText("\n", replacementRange: selectedRange()) }
    override func insertTab(_ sender: Any?) {
        let source = string as NSString, selection = selectedRange()
        let line = source.substring(with: source.lineRange(for: selection))
        if selection.length > 0 || line.range(of: #"^[ \t]*(?:[-+*] |\d+[.)] |> )"#, options: .regularExpression) != nil { apply(.indent) }
        else { insertText("    ", replacementRange: selection) }
    }
    override func insertBacktab(_ sender: Any?) { apply(.outdent) }
    override func deleteBackward(_ sender: Any?) {
        if !hasMarkedText(), let edit = MarkdownEditing.removeListPrefix(text: string, selection: selectedRange()) { apply(edit) }
        else { super.deleteBackward(sender) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        if modifiers == .command {
            switch key {
            case "b": apply(.bold); return true
            case "i": apply(.italic); return true
            case "k": apply(.link); return true
            case "f": showFindBar(); return true
            default: break
            }
        }
        if modifiers == [.command, .shift], key == "x" { apply(.toggleTask); return true }
        return super.performKeyEquivalent(with: event)
    }
    @objc func markdownBold(_ sender: Any?) { apply(.bold) }
    @objc func markdownItalic(_ sender: Any?) { apply(.italic) }
    @objc func markdownLink(_ sender: Any?) { apply(.link) }
    @objc func markdownTask(_ sender: Any?) { apply(.toggleTask) }
    @objc func markdownFind(_ sender: Any?) { showFindBar() }
    private func showFindBar() {
        let item = NSMenuItem(); item.tag = NSTextFinder.Action.showFindInterface.rawValue
        performTextFinderAction(item)
    }

    func apply(_ command: MarkdownCommand) {
        if hasMarkedText() { unmarkText() }
        guard let edit = MarkdownEditing.edit(command, text: string, selection: selectedRange()) else { return }
        window?.makeFirstResponder(self); apply(edit)
    }
    private func apply(_ edit: MarkdownEdit) {
        breakUndoCoalescing()
        insertText(edit.replacement, replacementRange: edit.range)
        setSelectedRange(edit.selection); scrollRangeToVisible(edit.selection)
        breakUndoCoalescing(); highlight()
    }
    func scheduleHighlight() {
        highlightTask?.cancel()
        highlightTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.highlight()
        }
    }
    func highlight() {
        guard !hasMarkedText(), !rendering, !trackingSelection, let storage = textStorage else { return }
        let selection = editingFocused ? selectedRange() : nil
        let line = selection.map { (string as NSString).lineRange(for: $0) }
        let changed = document?.source != string
        guard changed || line != revealedLine else { return }
        rendering = true; defer { rendering = false }
        if changed { document = LiveMarkdownDocument(string) }
        revealedLine = line
        guard let document else { return }
        let result = document.presentation(selection: selection)
        if let layout = layoutManager as? LiveMarkdownLayoutManager {
            layout.hidden = result.hidden; layout.markers = result.markers; layout.codeBlocks = document.codeBlocks
        }
        let origin = enclosingScrollView?.contentView.bounds.origin
        storage.beginEditing()
        result.text.enumerateAttributes(in: NSRange(location: 0, length: result.text.length)) { attributes, range, _ in
            storage.setAttributes(attributes, range: range)
        }
        storage.endEditing()
        // Styling replaces the IME's Korean fallback font with the system font.
        // Resolve coverage before regenerating glyphs; otherwise Hangul can stay
        // as zero/null glyphs until the editor is reloaded.
        storage.fixFontAttribute(in: NSRange(location: 0, length: storage.length))
        layoutManager?.invalidateGlyphs(forCharacterRange: NSRange(location: 0, length: storage.length), changeInLength: 0, actualCharacterRange: nil)
        layoutManager?.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
        layoutManager?.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: storage.length))
        typingAttributes = MarkdownStyle.body
        if let origin, let scroll = enclosingScrollView {
            scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView)
        }
        if changed, editingFocused { scrollRangeToVisible(selectedRange()) }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }
}

@MainActor enum MarkdownStyle {
    static var body: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 7; paragraph.lineBreakStrategy = .hangulWordPriority
        return [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor(SoriTheme.ink), .paragraphStyle: paragraph]
    }
}
