import AppKit
import SoriCore

/// Synthetic, offscreen-only transcript for the return-to-playback control.
@MainActor enum TranscriptPreview {
    static func configure(store: AppStore, arguments: [String]) {
        guard arguments.contains("--snapshot"), arguments.contains("--follow-return-preview"),
              let index = store.recordings.firstIndex(where: { $0.id == store.selectedID }) else { return }
        let paragraphs = [
            "가격이 변하면 수요량도 달라집니다. 오늘은 이 반응의 크기를 어떻게 비교하는지 살펴보겠습니다.",
            "단순한 변화량보다 변화율이 중요합니다. 단위가 다른 상품도 같은 기준으로 비교할 수 있기 때문입니다.",
            "수요의 가격탄력성은 가격 변화율에 대한 수요량 변화율의 비율입니다. 두 변화율을 구분해서 보세요.",
            "음의 부호는 가격과 수요량이 반대로 움직인다는 뜻입니다. 크기를 비교할 때는 절댓값을 사용합니다.",
            "대체재가 많은 상품은 소비자가 다른 상품으로 옮겨 가기 쉽습니다. 가격에 대한 반응도 달라질 수 있습니다."
        ]
        store.recordings[index].title = "수요의 가격탄력성"
        store.recordings[index].lectureHighlights = nil
        store.recordings[index].segments = (0..<25).map {
            .init(id: $0, start: Double($0), end: Double($0 + 1), text: paragraphs[$0 % paragraphs.count])
        }
        store.audio.currentTime = 12.5
    }

    static func scrollAway(in view: NSView, arguments: [String]) {
        guard arguments.contains("--snapshot"), arguments.contains("--follow-return-preview") else { return }
        if let scroll = view as? TranscriptScrollView, let text = scroll.documentView {
            scroll.followPaused = true
            let y = arguments.contains("--follow-above-preview") ? max(0, text.bounds.height - scroll.contentSize.height) : 0
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        } else {
            for child in view.subviews { scrollAway(in: child, arguments: arguments) }
        }
    }
}
