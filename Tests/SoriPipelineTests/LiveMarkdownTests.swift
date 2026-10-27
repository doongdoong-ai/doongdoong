import AppKit
import SwiftUI
import XCTest
@testable import SoriApp

@MainActor final class LiveMarkdownTests: XCTestCase {
    private func visible(_ doc: LiveMarkdownDocument, selection: NSRange? = nil) -> String {
        let hidden = doc.presentation(selection: selection).hidden
        return String(decoding: Array(doc.source.utf16).enumerated().filter { !hidden.contains($0.offset) }.map(\.element), as: UTF16.self)
    }

    func testLivePreviewUsesOriginalUnicodeRangesAndPreservesRawMarkdown() throws {
        let source = "# 금융 👩‍💻\n\n**핵심 _중첩_** 과 `코드`\n\n[자료](https://example.com)\n"
        let doc = LiveMarkdownDocument(source)
        XCTAssertEqual(doc.styled.string, source)
        XCTAssertEqual(visible(doc), "금융 👩‍💻\n\n핵심 중첩 과 코드\n\n자료\n")
        let heading = try XCTUnwrap(doc.styled.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(heading.pointSize, 28)
        let range = (source as NSString).range(of: "중첩")
        let nested = try XCTUnwrap(doc.styled.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
        let traits = NSFontManager.shared.traits(of: nested)
        XCTAssertTrue(traits.contains(.boldFontMask)); XCTAssertTrue(traits.contains(.italicFontMask))
    }

    func testOnlyCursorLineRevealsSyntaxAndRestOfDocumentStaysRendered() {
        let source = "# 제목\n\n본문 **중요**\n\n- [ ] 복습\n"
        let doc = LiveMarkdownDocument(source)
        let selection = (source as NSString).range(of: "중요")
        XCTAssertEqual(visible(doc, selection: selection), "제목\n\n본문 **중요**\n\n복습\n")
        XCTAssertEqual(visible(doc), "제목\n\n본문 중요\n\n복습\n")
        let all = NSRange(location: 0, length: (source as NSString).length)
        XCTAssertEqual(visible(doc, selection: all), source)
    }

    func testEscapedUnfinishedAndFencedMarkdownNeverLosesLiteralContent() {
        let source = "\\*문자\\*와 **아직 입력 중\n\n```swift\nlet text = \"**그대로**\"\n```\n"
        let doc = LiveMarkdownDocument(source)
        let displayed = visible(doc)
        XCTAssertTrue(displayed.contains("문자")); XCTAssertTrue(displayed.contains("**아직 입력 중"))
        XCTAssertTrue(displayed.contains("let text = \"**그대로**\""))
        XCTAssertFalse(displayed.contains("```"))
        XCTAssertEqual(doc.styled.string, source)
        XCTAssertEqual(doc.codeBlocks.count, 1)
        let inside = (source as NSString).range(of: "let text")
        XCTAssertTrue(visible(doc, selection: inside).contains("```swift"))
    }

    func testTaskWidgetsKeepOriginalPositionsAndToggleWithoutMovingCaret() throws {
        var value = "# 수업\n\n- [ ] 한국어 👩‍💻 복습\n- [x] 완료\n"
        let controller = MarkdownEditorController()
        let view = MarkdownNotesEditor(text: Binding(get: { value }, set: { value = $0 }), controller: controller)
        let coordinator = view.makeCoordinator()
        let scroll = view.makeScrollView(coordinator: coordinator)
        // Retain the actual delegate throughout this test.
        (scroll.documentView as? NSTextView)?.delegate = coordinator
        let editor = try XCTUnwrap(controller.textView), layout = try XCTUnwrap(editor.layoutManager as? LiveMarkdownLayoutManager)
        let tasks = layout.markers.filter { $0.taskIndex != nil }
        XCTAssertEqual(tasks.count, 2)
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        editor.toggleTask(at: try XCTUnwrap(tasks.first?.taskIndex))
        XCTAssertTrue(value.contains("- [x] 한국어 👩‍💻 복습"))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: 0))
        editor.toggleTask(at: try XCTUnwrap(tasks.first?.taskIndex))
        XCTAssertTrue(value.contains("- [ ] 한국어 👩‍💻 복습"))
    }

    func testFoldedGlyphsOccupyNoWidthAndCopyStillUsesSource() throws {
        let source = "# 제목\n\n본문 **한국어**\n"
        let controller = MarkdownEditorController(), view = MarkdownNotesEditor(text: .constant(source), controller: MarkdownEditorController())
        let coordinator = view.makeCoordinator()
        let scroll = view.makeScrollView(coordinator: coordinator)
        let editor = try XCTUnwrap(scroll.documentView as? MarkdownTextView)
        editor.delegate = coordinator
        controller.textView = editor
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let layout = try XCTUnwrap(editor.layoutManager as? LiveMarkdownLayoutManager)
        layout.ensureLayout(for: try XCTUnwrap(editor.textContainer))
        let first = layout.glyphIndexForCharacter(at: 0)
        XCTAssertTrue(layout.propertyForGlyph(at: first).contains(.null))
        XCTAssertEqual(layout.location(forGlyphAt: layout.glyphIndexForCharacter(at: 2)).x, 0, accuracy: 0.5)
        editor.setSelectedRange(NSRange(location: 0, length: (source as NSString).length))
        let clipboard = NSPasteboard.withUniqueName(); defer { clipboard.releaseGlobally() }
        XCTAssertTrue(editor.writeSelection(to: clipboard, types: editor.writablePasteboardTypes))
        XCTAssertEqual(clipboard.string(forType: .string), source)
    }

    func testListIndentOutdentAndBackspaceAreReversibleAndKeepKorean() throws {
        var source = "- 첫째\n- 👩‍💻 둘째"
        let selection = NSRange(location: 0, length: (source as NSString).length)
        let indent = try XCTUnwrap(MarkdownEditing.edit(.indent, text: source, selection: selection))
        source = (source as NSString).replacingCharacters(in: indent.range, with: indent.replacement)
        XCTAssertEqual(source, "    - 첫째\n    - 👩‍💻 둘째")
        let outdent = try XCTUnwrap(MarkdownEditing.edit(.outdent, text: source, selection: indent.selection))
        source = (source as NSString).replacingCharacters(in: outdent.range, with: outdent.replacement)
        XCTAssertEqual(source, "- 첫째\n- 👩‍💻 둘째")
        let backspace = try XCTUnwrap(MarkdownEditing.removeListPrefix(text: "- [ ] 할 일", selection: NSRange(location: 6, length: 0)))
        XCTAssertEqual(("- [ ] 할 일" as NSString).replacingCharacters(in: backspace.range, with: backspace.replacement), "할 일")
    }

    func testUnsafeLinksRemainTextAndHighlightDoesNotAffectCode() {
        let source = "[링크](javascript:alert)\n\n==핵심==\n\n`==인라인==`\n\n```\n==코드==\n```"
        let doc = LiveMarkdownDocument(source)
        let link = (source as NSString).range(of: "링크")
        XCTAssertNil(doc.styled.attribute(.markdownURL, at: link.location, effectiveRange: nil))
        XCTAssertTrue(visible(doc).contains("핵심")); XCTAssertFalse(visible(doc).contains("==핵심=="))
        XCTAssertTrue(visible(doc).contains("==코드=="))
        XCTAssertTrue(visible(doc).contains("==인라인=="))
    }

    func testFormatCommandsConvertExistingListRatherThanStackingPrefixes() throws {
        let source = "- 👩‍💻 복습"
        let edit = try XCTUnwrap(MarkdownEditing.edit(.toggleTask, text: source, selection: NSRange(location: (source as NSString).length, length: 0)))
        XCTAssertEqual((source as NSString).replacingCharacters(in: edit.range, with: edit.replacement), "- [ ] 👩‍💻 복습")
        let title = "# 제목"
        let heading = try XCTUnwrap(MarkdownEditing.edit(.heading, text: title, selection: NSRange(location: 4, length: 0)))
        XCTAssertEqual((title as NSString).replacingCharacters(in: heading.range, with: heading.replacement), "## 제목")
        let bold = try XCTUnwrap(MarkdownEditing.edit(.bold, text: "", selection: NSRange(location: 0, length: 0)))
        XCTAssertEqual(bold.replacement, "****"); XCTAssertEqual(bold.selection, NSRange(location: 2, length: 0))
    }

    func testEditorReflowsLongKoreanLinesAtNarrowAndExpandedWidths() throws {
        let text = String(repeating: "한국어 강의 필기는 창 너비에 맞게 자연스럽게 줄바꿈되어야 합니다. ", count: 12)
        let controller = MarkdownEditorController()
        let view = MarkdownNotesEditor(text: .constant(text), controller: controller)
        let coordinator = view.makeCoordinator(), scroll = view.makeScrollView(coordinator: coordinator)
        let editor = try XCTUnwrap(controller.textView), container = try XCTUnwrap(editor.textContainer)
        let layout = try XCTUnwrap(editor.layoutManager)
        var heights: [CGFloat] = []
        for width: CGFloat in [380, 800, 380] {
            scroll.frame = NSRect(x: 0, y: 0, width: width, height: 400)
            scroll.tile(); scroll.layoutSubtreeIfNeeded()
            layout.ensureLayout(for: container)
            XCTAssertEqual(editor.frame.width, scroll.contentSize.width, accuracy: 1)
            XCTAssertLessThanOrEqual(container.size.width, scroll.contentSize.width)
            let used = layout.usedRect(for: container)
            XCTAssertLessThanOrEqual(used.maxX, container.size.width + 1)
            heights.append(used.height)
        }
        XCTAssertGreaterThan(heights[0], heights[1])
        XCTAssertEqual(heights[0], heights[2], accuracy: 1)
    }
}
