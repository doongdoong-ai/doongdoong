import SwiftUI
import SoriCore

/// Snapshot fixtures only; no microphone, speech recognition or AI requests.
@MainActor enum RecordingPreview {
    static func configure(store: AppStore, arguments: [String]) {
        guard arguments.contains("--recording-only-preview") || arguments.contains("--workspace-preview") || arguments.contains("--saved-notes-preview"),
              let id = store.selectedID, let index = store.recordings.firstIndex(where: { $0.id == id }) else { return }
        if arguments.contains("--saved-notes-preview") {
            store.recordings[index].notes = arguments.contains("--notes-composing-preview") ? "## 수업 필기\n\n\n\n- [ ] 복습하기" : sampleNotes
            store.recordings[index].title = "금융 세계화와 자본 통제"
            store.showNotes = true
            if arguments.contains("--library-search-preview") { store.search = "금융" }
            if arguments.contains("--favorites-preview") { store.recordings[index].isFavorite = true; store.favoritesOnly = true }
            if arguments.contains("--folder-library-preview") { store.selectCollection(store.recordings[index].projectID) }
            return
        }
        store.recordings[index].recordingMode = .audioOnly
        store.recordings[index].status = .saved
        store.recordings[index].segments = []
        store.recordings[index].lectureHighlights = nil
        store.recordings[index].generatedTitle = nil
        store.recordings[index].work = nil
        store.recordings[index].isDemo = false
        store.recordings[index].title = "금융과 세계 경제 · 10.27 14:00"
        if arguments.contains("--recording-active-preview") {
            store.recordings[index].status = .recording
            store.recordingID = id
            store.audio.isRecording = true
            store.audio.recordingTime = 1234
        }
        if arguments.contains("--workspace-preview") {
            store.recordings[index].recordingMode = .lecture
            store.recordings[index].status = .recording
            store.recordingID = id
            store.audio.isRecording = true
            store.audio.recordingTime = 2634
            store.audio.isPausedRecording = arguments.contains("--recorder-paused-preview")
            store.audio.liveLevels = (0..<80).map { index -> Float in
                let carrier = abs(sin(Double(index) * 0.53))
                let envelope = 0.18 + 0.6 * abs(sin(Double(index) * 0.12))
                return Float(0.08 + carrier * envelope)
            }
            store.recordings[index].notes = arguments.contains("--notes-empty-preview") ? "" : sampleNotes
        }
    }

    static let sampleNotes = """
    # 금융 세계화와 자본 통제

    ## 오늘의 핵심

    브레튼우즈 체제에서는 **단기 자본의 이동**을 통제했다.
    상품 교역이나 장기 투자까지 막았다는 뜻은 아니다.

    - 자본 통제: 국경을 넘는 단기 금융의 이동을 제한
    - 고정 환율: 국가 간 협의로 환율을 결정
    - 재량적 경제 정책: 국내 상황에 맞게 정책을 운용

    > 이 세 가지의 관계를 이해하는 것이 중요하다.

    ## 다시 확인할 것

    - [ ] 자본 통제와 통제 경제의 차이 정리하기
    - [ ] 국제 경제의 트릴레마 그림으로 그려보기

    [32:10] 무역 적자가 생기면 국제 수지는 어떻게 맞춰질까?
    """

    static func prepareEditor(in view: NSView, arguments: [String]) {
        guard arguments.contains("--live-edit-preview") || arguments.contains("--notes-composing-preview") else { return }
        func find(_ view: NSView) -> MarkdownTextView? {
            if let text = view as? MarkdownTextView { return text }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        guard let editor = find(view) else { return }
        if arguments.contains("--notes-composing-preview") {
            _ = editor.becomeFirstResponder()
            editor.setSelectedRange(NSRange(location: ("## 수업 필기\n\n" as NSString).length, length: 0))
            let text = "한글을 입력하는 중에도 바로 보여야 합니다"
            editor.setMarkedText(NSAttributedString(string: text, attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue]),
                                 selectedRange: NSRange(location: (text as NSString).length, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
            return
        }
        editor.setSelectedRange((editor.string as NSString).range(of: "단기 자본의 이동"))
        _ = editor.becomeFirstResponder()
        editor.highlight()
    }

}
