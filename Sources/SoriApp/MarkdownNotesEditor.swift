import AppKit
import SwiftUI

@MainActor final class MarkdownEditorController {
    weak var textView: MarkdownTextView?
    func perform(_ command: MarkdownCommand) {
        textView?.isEditable = true
        textView?.isSelectable = true
        textView?.apply(command)
    }
    func focus() {
        guard let textView else { return }
        textView.isEditable = true; textView.isSelectable = true
        textView.window?.makeFirstResponder(textView)
    }
    func endComposition() { textView?.unmarkText() }
    func blur() {
        endComposition()
        if let textView, textView.window?.firstResponder === textView { textView.window?.makeFirstResponder(nil) }
    }
}

struct MarkdownNotesEditor: NSViewRepresentable {
    @Binding var text: String
    let controller: MarkdownEditorController
    var isEditing = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        makeScrollView(coordinator: context.coordinator)
    }

    func makeScrollView(coordinator: Coordinator) -> NSScrollView {
        let scroll = Self.scrollView()
        let editor = MarkdownTextView(frame: scroll.bounds)
        Self.configure(editor)
        editor.isEditable = isEditing; editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.setAccessibilityLabel("수업 필기 마크다운 편집기")
        editor.setAccessibilityHelp("제목, 목록, 굵게 등 마크다운을 사용할 수 있습니다. 작성한 내용은 자동으로 저장됩니다.")
        editor.string = text
        editor.highlight()
        editor.delegate = coordinator
        scroll.documentView = editor
        controller.textView = editor
        editor.isEditable = isEditing
        editor.isSelectable = isEditing
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(self, scroll: scroll)
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownNotesEditor
        init(_ parent: MarkdownNotesEditor) { self.parent = parent }
        func update(_ parent: MarkdownNotesEditor, scroll: NSScrollView) {
            self.parent = parent
            guard let editor = scroll.documentView as? MarkdownTextView else { return }
            parent.controller.textView = editor
            editor.isEditable = parent.isEditing
            editor.isSelectable = parent.isEditing
            // Resizing and metering must never replace the native text document.
            if editor.string != parent.text, !editor.hasMarkedText() {
                let selection = editor.selectedRange()
                editor.string = parent.text
                editor.setSelectedRange(NSRange(location: min(selection.location, (parent.text as NSString).length), length: 0))
                editor.highlight()
            }
        }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? MarkdownTextView else { return }
            parent.text = editor.string
            editor.scheduleHighlight()
        }
    }

    static func scrollView() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay; scroll.drawsBackground = false
        scroll.focusRingType = .none
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = .init()
        scroll.contentView.automaticallyAdjustsContentInsets = false
        scroll.contentView.contentInsets = .init()
        return scroll
    }

    static func configure(_ text: NSTextView) {
        text.isSelectable = true; text.drawsBackground = false
        text.focusRingType = .none; text.isVerticallyResizable = true
        text.isHorizontallyResizable = false; text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.heightTracksTextView = false
        text.textContainer?.containerSize.height = .greatestFiniteMagnitude
        text.textContainer?.lineFragmentPadding = 0
        text.textContainerInset = NSSize(width: 6, height: 22)
        text.insertionPointColor = NSColor(SoriTheme.ink)
        text.selectedTextAttributes = [.backgroundColor: NSColor(SoriTheme.ink).withAlphaComponent(0.12)]
        text.typingAttributes = MarkdownStyle.body
    }
}

final class MarkdownTextView: NSTextView {
    private var highlightTask: Task<Void, Never>?

    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }

    override func insertNewline(_ sender: Any?) {
        // Return confirms a Korean IME composition before it can continue a list.
        guard !hasMarkedText(), let edit = MarkdownEditing.newline(text: string, selection: selectedRange()) else {
            super.insertNewline(sender); return
        }
        apply(edit)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "b": apply(.bold); return true
            case "i": apply(.italic); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc func markdownBold(_ sender: Any?) { apply(.bold) }
    @objc func markdownItalic(_ sender: Any?) { apply(.italic) }

    func apply(_ command: MarkdownCommand) {
        if hasMarkedText() { unmarkText() }
        guard let edit = MarkdownEditing.edit(command, text: string, selection: selectedRange()) else { return }
        window?.makeFirstResponder(self)
        apply(edit)
    }

    private func apply(_ edit: MarkdownEdit) {
        breakUndoCoalescing()
        insertText(edit.replacement, replacementRange: edit.range)
        setSelectedRange(edit.selection)
        scrollRangeToVisible(edit.selection)
        breakUndoCoalescing()
        highlight()
    }

    func scheduleHighlight() {
        highlightTask?.cancel()
        highlightTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.highlight()
        }
    }

    func highlight() {
        // Attribute edits while marked text is active break Korean composition.
        guard !hasMarkedText(), let storage = textStorage else { return }
        storage.beginEditing()
        storage.setAttributes(MarkdownStyle.body, range: NSRange(location: 0, length: storage.length))
        MarkdownStyle.highlight(storage)
        storage.endEditing()
        typingAttributes = MarkdownStyle.body
    }
}

@MainActor enum MarkdownStyle {
    static var body: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 7
        paragraph.lineBreakStrategy = .hangulWordPriority
        return [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor(SoriTheme.ink), .paragraphStyle: paragraph]
    }

    private static let rules: [(String, NSRegularExpression.Options, [NSAttributedString.Key: Any])] = [
        (#"^#\s+.+$"#, [.anchorsMatchLines], [.font: NSFont.systemFont(ofSize: 26, weight: .semibold)]),
        (#"^##\s+.+$"#, [.anchorsMatchLines], [.font: NSFont.systemFont(ofSize: 21, weight: .semibold)]),
        (#"^#{3,6}\s+.+$"#, [.anchorsMatchLines], [.font: NSFont.systemFont(ofSize: 18, weight: .semibold)]),
        (#"\*\*[^*\n]+\*\*"#, [], [.font: NSFont.systemFont(ofSize: 16, weight: .semibold)]),
        (#"(?<!\*)\*[^*\n]+\*(?!\*)"#, [], [.font: NSFontManager.shared.convert(.systemFont(ofSize: 16), toHaveTrait: .italicFontMask)]),
        (#"`[^`\n]+`"#, [], [.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular), .backgroundColor: NSColor(SoriTheme.sidebar)]),
        (#"^\s*(?:#{1,6} |[-+*] (?:\[[ xX]\] )?|\d+\. |> )"#, [.anchorsMatchLines], [.foregroundColor: NSColor(SoriTheme.secondary)]),
        (#"^> .+$"#, [.anchorsMatchLines], [.foregroundColor: NSColor(SoriTheme.secondary)])
    ]
    private static let compiled = rules.compactMap { pattern, options, attributes -> (NSRegularExpression, [NSAttributedString.Key: Any])? in
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        return (regex, attributes)
    }

    static func highlight(_ storage: NSMutableAttributedString) {
        let text = storage.string, range = NSRange(location: 0, length: storage.length)
        for (regex, attributes) in compiled {
            for match in regex.matches(in: text, range: range) { storage.addAttributes(attributes, range: match.range) }
        }
    }

    static func preview(_ source: String) -> NSAttributedString {
        guard let markdown = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .full)) else {
            return NSAttributedString(string: source, attributes: body)
        }
        let output = NSMutableAttributedString()
        var seenItems = Set<Int>()
        for (intent, range) in markdown.runs[\.presentationIntent] {
            let components = intent?.components ?? []
            var heading = 0, code = false, quoted = false, listDepth = 0
            var item: (id: Int, ordinal: Int)?
            var ordered = false
            for component in components {
                switch component.kind {
                case .header(let level): heading = level
                case .codeBlock: code = true
                case .blockQuote: quoted = true
                case .listItem(let ordinal): if item == nil { item = (component.identity, ordinal) }
                case .orderedList: listDepth += 1; if listDepth == 1 { ordered = true }
                case .unorderedList: listDepth += 1
                default: break
                }
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = code ? 5 : 7
            paragraph.paragraphSpacing = heading > 0 ? 16 : 12
            paragraph.paragraphSpacingBefore = heading > 0 && output.length > 0 ? 14 : 0
            paragraph.lineBreakStrategy = .hangulWordPriority
            paragraph.headIndent = CGFloat(listDepth) * 20 + (quoted ? 18 : 0)
            paragraph.firstLineHeadIndent = max(0, paragraph.headIndent - (item == nil ? 0 : 16))
            let size: CGFloat = heading == 1 ? 28 : heading == 2 ? 23 : heading > 0 ? 19 : code ? 14 : 16
            var base = body
            base[.paragraphStyle] = paragraph
            base[.foregroundColor] = NSColor(quoted ? SoriTheme.secondary : SoriTheme.ink)
            if code { base[.backgroundColor] = NSColor(SoriTheme.sidebar) }
            base[.font] = code ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size, weight: heading > 0 ? .semibold : .regular)
            let blockText = String(markdown[range].characters)
            let unchecked = item != nil && blockText.hasPrefix("[ ] ")
            let checked = item != nil && (blockText.hasPrefix("[x] ") || blockText.hasPrefix("[X] "))
            if let item, seenItems.insert(item.id).inserted {
                let marker = unchecked ? "☐  " : checked ? "☑  " : ordered ? "\(item.ordinal).  " : "•  "
                output.append(NSAttributedString(string: marker, attributes: base))
            }
            if quoted { output.append(NSAttributedString(string: "│  ", attributes: base)) }
            var prefixToSkip = unchecked || checked ? 4 : 0
            for run in markdown[range].runs {
                var attributes = base
                let inline = run.inlinePresentationIntent ?? []
                var font = NSFont.systemFont(ofSize: size, weight: inline.contains(.stronglyEmphasized) || heading > 0 ? .semibold : .regular)
                if inline.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                if code || inline.contains(.code) {
                    font = .monospacedSystemFont(ofSize: 14, weight: .regular)
                    attributes[.backgroundColor] = NSColor(SoriTheme.sidebar)
                }
                if inline.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if let link = run.link, ["https", "http", "mailto"].contains(link.scheme?.lowercased() ?? "") {
                    attributes[.link] = link
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
                attributes[.font] = font
                let raw = String(markdown[run.range].characters)
                let skip = min(prefixToSkip, raw.count)
                prefixToSkip -= skip
                output.append(NSAttributedString(string: String(raw.dropFirst(skip)), attributes: attributes))
            }
            output.append(NSAttributedString(string: "\n", attributes: base))
        }
        return output
    }
}

struct MarkdownNotesPreview: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = MarkdownNotesEditor.scrollView()
        let reader = NSTextView(frame: scroll.bounds)
        MarkdownNotesEditor.configure(reader)
        reader.isEditable = false; reader.isRichText = true
        reader.setAccessibilityLabel("수업 필기 미리보기")
        reader.linkTextAttributes = [.foregroundColor: NSColor(SoriTheme.ink), .underlineStyle: NSUnderlineStyle.single.rawValue]
        scroll.documentView = reader
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let reader = scroll.documentView as? NSTextView, context.coordinator.source != text else { return }
        context.coordinator.source = text
        reader.textStorage?.setAttributedString(MarkdownStyle.preview(text))
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var source: String? }
}
