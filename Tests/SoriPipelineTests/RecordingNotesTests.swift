import AppKit
import SwiftUI
import XCTest
import SoriCore
@testable import SoriApp

@MainActor final class RecordingNotesTests: XCTestCase {
    func testFormattingKoreanAndEmojiPreservesSelectionAndToggles() throws {
        let text = "수업 👩‍💻 금융 세계화 정리"
        let selection = (text as NSString).range(of: "👩‍💻 금융 세계화")
        let bold = try XCTUnwrap(MarkdownEditing.edit(.bold, text: text, selection: selection))
        let result = (text as NSString).replacingCharacters(in: bold.range, with: bold.replacement)
        XCTAssertEqual(result, "수업 **👩‍💻 금융 세계화** 정리")
        XCTAssertEqual((result as NSString).substring(with: bold.selection), "👩‍💻 금융 세계화")
        let undo = try XCTUnwrap(MarkdownEditing.edit(.bold, text: result, selection: bold.selection))
        XCTAssertEqual((result as NSString).replacingCharacters(in: undo.range, with: undo.replacement), text)
        XCTAssertNil(MarkdownEditing.edit(.bold, text: text, selection: NSRange(location: NSNotFound, length: 0)))
    }

    func testMultilineFormattingDoesNotIncludeNextUnselectedLine() throws {
        let source = "첫 줄\n둘째 줄\n마지막 줄"
        let selected = (source as NSString).range(of: "첫 줄\n둘째 줄\n")
        let edit = try XCTUnwrap(MarkdownEditing.edit(.bullet, text: source, selection: selected))
        let result = (source as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        XCTAssertEqual(result, "- 첫 줄\n- 둘째 줄\n마지막 줄")
        let toggle = try XCTUnwrap(MarkdownEditing.edit(.bullet, text: result, selection: edit.selection))
        XCTAssertEqual((result as NSString).replacingCharacters(in: toggle.range, with: toggle.replacement), source)
    }

    func testListsContinueAndEmptyItemsExitWithoutDeletingPriorText() throws {
        for (source, expected) in [("- 개념 정리", "- 개념 정리\n- "), ("9. 개념", "9. 개념\n10. "),
                                   ("  - [x] 복습", "  - [x] 복습\n  - [ ] "), ("> 인용", "> 인용\n> "),
                                   ("메모\n- ", "메모\n")] {
            let edit = try XCTUnwrap(MarkdownEditing.newline(text: source, selection: NSRange(location: (source as NSString).length, length: 0)))
            XCTAssertEqual((source as NSString).replacingCharacters(in: edit.range, with: edit.replacement), expected)
        }
        XCTAssertNil(MarkdownEditing.newline(text: "평문", selection: NSRange(location: 2, length: 0)))
    }

    func testNativeFormattingKeepsUndoAndSelectionAfterResize() throws {
        let editor = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        let delegate = NotesUndoDelegate()
        editor.delegate = delegate; editor.isRichText = false; editor.allowsUndo = true
        editor.string = "핵심 개념 👩‍💻"
        let selection = (editor.string as NSString).range(of: "개념 👩‍💻")
        editor.setSelectedRange(selection)
        delegate.undo.beginUndoGrouping()
        editor.apply(.bold)
        delegate.undo.endUndoGrouping()
        XCTAssertEqual(editor.string, "핵심 **개념 👩‍💻**")
        let after = editor.selectedRange()
        editor.setFrameSize(NSSize(width: 820, height: 480)); editor.highlight()
        XCTAssertEqual(editor.selectedRange(), after)
        XCTAssertTrue(delegate.undo.canUndo)
        delegate.undo.undo()
        XCTAssertEqual(editor.string, "핵심 개념 👩‍💻")
        delegate.undo.redo()
        XCTAssertEqual(editor.string, "핵심 **개념 👩‍💻**")
    }

    func testHighlightDoesNotModifyKoreanMarkedText() {
        let editor = MarkdownTextView(frame: .zero)
        editor.isRichText = false; editor.string = "- "
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        editor.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let marked = editor.markedRange(), before = editor.attributedString()
        XCTAssertTrue(editor.hasMarkedText())
        editor.highlight()
        XCTAssertEqual(editor.markedRange(), marked)
        XCTAssertEqual(editor.attributedString(), before)
        editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.insertText("한국어", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(editor.string, "- 한국어")
        XCTAssertFalse(editor.hasMarkedText())
    }

    func testPreviewAndLayoutUpdatesKeepDocumentSelectionAndDisableHiddenEditing() throws {
        var value = "첫 문장\n둘째 문장 👩‍💻"
        let binding = Binding(get: { value }, set: { value = $0 })
        let controller = MarkdownEditorController()
        let initial = MarkdownNotesEditor(text: binding, controller: controller)
        let coordinator = initial.makeCoordinator()
        let scroll = initial.makeScrollView(coordinator: coordinator)
        let editor = try XCTUnwrap(controller.textView)
        let storage = editor.textStorage
        let selection = (value as NSString).range(of: "둘째 문장 👩‍💻")
        editor.setSelectedRange(selection)
        scroll.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        coordinator.update(MarkdownNotesEditor(text: binding, controller: controller, isEditing: false), scroll: scroll)
        XCTAssertTrue(editor.textStorage === storage)
        XCTAssertFalse(editor.isEditable)
        XCTAssertFalse(editor.isSelectable)
        coordinator.update(initial, scroll: scroll)
        XCTAssertTrue(editor.isEditable)
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertEqual(editor.string, value)
        editor.apply(.bold)
        XCTAssertEqual(value, "첫 문장\n**둘째 문장 👩‍💻**")
    }

    func testEndingCompositionPublishesLatestKoreanBeforeSave() throws {
        var value = ""
        let controller = MarkdownEditorController()
        let view = MarkdownNotesEditor(text: Binding(get: { value }, set: { value = $0 }), controller: controller)
        let coordinator = view.makeCoordinator()
        let scroll = view.makeScrollView(coordinator: coordinator)
        let editor = try XCTUnwrap(scroll.documentView as? MarkdownTextView)
        editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        controller.endComposition()
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(value, "한")
    }

    func testPreviewPreservesBlockBoundariesAndStylesWithoutUnsafeLinks() throws {
        let rendered = MarkdownStyle.preview("# 제목\n\n본문 **핵심**\n\n- 첫 항목\n- 둘째 항목\n\n> 인용\n\n[링크](javascript:alert)")
        XCTAssertTrue(rendered.string.contains("제목\n본문 핵심\n"))
        XCTAssertTrue(rendered.string.contains("•  첫 항목\n•  둘째 항목\n"))
        let title = try XCTUnwrap(rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(title.pointSize, 28)
        let range = (rendered.string as NSString).range(of: "링크")
        XCTAssertNil(rendered.attribute(.link, at: range.location, effectiveRange: nil))
        let tasks = MarkdownStyle.preview("- [ ] 미완료\n- [x] 완료")
        XCTAssertEqual(tasks.string, "☐  미완료\n☑  완료\n")
    }

    func testAutosaveBelongsToRecordingAndDoesNotOverwritePendingEdit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString)")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: root.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: root.lastPathComponent); try? FileManager.default.removeItem(at: root) }
        let store = AppStore(root: root, settings: AppSettings(defaults: defaults))
        let repo = try XCTUnwrap(store.repository), project = try XCTUnwrap(store.projects.first)
        let first = try repo.createRecording(project: project, title: "금융"), second = try repo.createRecording(project: project, title: "사회")
        store.recordings = [first, second]
        let draft = RecordingNotesDraft(store: store, recording: first)
        draft.text = "## 한국어 👩‍💻 필기"
        draft.synchronize("외부에서 늦게 도착한 값")
        store.selectedID = second.id
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertFalse(draft.isDirty)
        XCTAssertEqual(try repo.load().recordings.first(where: { $0.id == first.id })?.notes, "## 한국어 👩‍💻 필기")
        XCTAssertEqual(try repo.load().recordings.first(where: { $0.id == second.id })?.notes, "")
        draft.text += "\n종료 직전 작성"
        XCTAssertTrue(draft.flush())
        XCTAssertEqual(try repo.load().recordings.first(where: { $0.id == first.id })?.notes, draft.text)
    }
}

@MainActor private final class NotesUndoDelegate: NSObject, NSTextViewDelegate {
    let undo = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { undo }
}
