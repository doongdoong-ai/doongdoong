import AppKit
import SwiftUI
import XCTest
import SoriCore
@testable import SoriApp

@MainActor final class TranscriptSelectionTests: XCTestCase {
    private let recordingID = UUID()
    private let segments = [
        TranscriptSegment(id: 7, start: 1, end: 4, text: "첫 문장 👩‍💻 가격탄력성", originalText: "첫 원문 👩‍💻 가격 탄력성"),
        TranscriptSegment(id: 42, start: 3601, end: 3605, text: "다음 문장 가격탄력성", originalText: "다음 원문 가격 탄력성")
    ]

    private func view(active: Int? = nil, original: Bool = false, canPlay: Bool = true,
                      play: @escaping (TranscriptSegment) -> Void = { _ in }) -> SelectableTranscriptView {
        SelectableTranscriptView(recordingID: recordingID, segments: segments, original: original,
                                 textSize: 22, query: "", selectedSearchID: nil, activeID: active, playbackTime: 1,
                                 followPlayback: true, scrollRequest: 0, searchScrollRequest: 0,
                                 canPlay: canPlay, canEdit: true, play: play, togglePlayback: {}, isLooping: { _ in false },
                                 isBookmarked: { _ in false }, edit: { _ in },
                                 repeatSegment: { _ in }, bookmark: { _ in }, copy: { _ in })
    }

    func testDocumentRangesUseUTF16AndPreserveOriginalAndSearchMatches() {
        for original in [false, true] {
            let document = TranscriptDocument(segments: segments, original: original, size: 22, query: "가격")
            XCTAssertEqual(document.entries.map(\.segment.id), [7, 42])
            for entry in document.entries {
                XCTAssertEqual((document.text.string as NSString).substring(with: entry.textRange),
                               original ? entry.segment.originalText : entry.segment.text)
                let link = document.text.attribute(.link, at: entry.range.location, effectiveRange: nil) as? URL
                XCTAssertEqual(link?.lastPathComponent, String(entry.segment.id))
            }
            XCTAssertEqual(document.matches.count, 2)
            XCTAssertTrue(document.matches.allSatisfy { (document.text.string as NSString).substring(with: $0) == "가격" })
            XCTAssertTrue(document.text.string.contains("1:00:01"))
        }
    }

    func testNativeSelectionCopiesAcrossSentencesEvenWithoutPlayableAudio() throws {
        let view = view(canPlay: false)
        let coordinator = view.makeCoordinator()
        let scroll = view.makeScrollView(coordinator: coordinator)
        scroll.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        coordinator.update(view, scroll: scroll)
        let text = try XCTUnwrap(scroll.documentView as? TranscriptTextView)
        let entries = try XCTUnwrap(coordinator.document?.entries)
        let range = NSRange(location: entries[0].textRange.location,
                            length: NSMaxRange(entries[1].textRange) - entries[0].textRange.location)
        text.setSelectedRange(range)
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        XCTAssertTrue(text.writeSelection(to: clipboard, types: text.writablePasteboardTypes))
        XCTAssertEqual(clipboard.string(forType: .string), (text.string as NSString).substring(with: range))
        XCTAssertTrue(clipboard.string(forType: .string)?.contains(segments[0].text) == true)
        XCTAssertTrue(clipboard.string(forType: .string)?.contains(segments[1].text) == true)
        XCTAssertFalse(text.isEditable)
    }

    func testPlaybackHighlightUpdatesPreserveSelectionAndCopyContents() throws {
        let initial = view(active: 7)
        let coordinator = initial.makeCoordinator()
        let scroll = initial.makeScrollView(coordinator: coordinator)
        coordinator.update(initial, scroll: scroll)
        let text = try XCTUnwrap(scroll.documentView as? TranscriptTextView)
        let range = try XCTUnwrap(coordinator.document?.entries.first?.textRange)
        text.setSelectedRange(range)
        let origin = scroll.contentView.bounds.origin
        coordinator.update(view(active: 42), scroll: scroll)
        XCTAssertEqual(text.selectedRange(), range)
        XCTAssertEqual(scroll.contentView.bounds.origin, origin)
        XCTAssertEqual((text.string as NSString).substring(with: text.selectedRange()), segments[0].text)
        let active = try XCTUnwrap(coordinator.document?.entries.last?.textRange)
        XCTAssertNotNil(text.textStorage?.attribute(.backgroundColor, at: active.location, effectiveRange: nil))
    }

    func testHighlightCardHeadingAndSummaryCanBeSelectedAndCopiedTogether() throws {
        let json = #"{"heading":"강조 제목","summary":"강의의 핵심 설명입니다.","signal":"explicit","evidence":[]}"#
        let card = try JSONDecoder().decode(LectureHighlight.self, from: Data(json.utf8))
        let host = NSHostingView(rootView: SelectableCardText(text: card.attributedText).frame(width: 500, height: 160))
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 160)
        host.layoutSubtreeIfNeeded()
        func findText(_ view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.lazy.compactMap { findText($0) }.first
        }
        let text = try XCTUnwrap(findText(host))
        text.selectAll(nil)
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        XCTAssertTrue(text.isSelectable)
        XCTAssertFalse(text.isEditable)
        XCTAssertTrue(text.writeSelection(to: clipboard, types: text.writablePasteboardTypes))
        XCTAssertEqual(clipboard.string(forType: .string), card.copyText)
    }

    func testSwitchingToOriginalClearsStaleSelectionAndUsesOriginalText() throws {
        let initial = view()
        let coordinator = initial.makeCoordinator()
        let scroll = initial.makeScrollView(coordinator: coordinator)
        coordinator.update(initial, scroll: scroll)
        let text = try XCTUnwrap(scroll.documentView as? TranscriptTextView)
        text.selectAll(nil)
        coordinator.update(view(original: true), scroll: scroll)
        XCTAssertEqual(text.selectedRange().length, 0)
        XCTAssertTrue(text.string.contains(segments[0].originalText))
        XCTAssertFalse(text.string.contains(segments[0].text))
    }

    func testOnlyTimestampLinkStartsPlayback() throws {
        var played: [Int] = []
        let view = view(play: { played.append($0.id) })
        let coordinator = view.makeCoordinator()
        let scroll = view.makeScrollView(coordinator: coordinator)
        coordinator.update(view, scroll: scroll)
        let text = try XCTUnwrap(scroll.documentView as? TranscriptTextView)
        let entry = try XCTUnwrap(coordinator.document?.entries.last)
        XCTAssertNil(text.textStorage?.attribute(.link, at: entry.textRange.location, effectiveRange: nil))
        text.setSelectedRange(entry.textRange)
        XCTAssertTrue(played.isEmpty)
        XCTAssertTrue(coordinator.textView(text, clickedOnLink: URL(string: "doongdoong://sentence/42")!, at: entry.range.location))
        XCTAssertEqual(played, [42])
    }
}
