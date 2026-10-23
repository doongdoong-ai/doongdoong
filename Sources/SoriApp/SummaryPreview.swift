import Foundation
import SoriCore

/// Synthetic lecture content for offscreen layout checks only; never saved.
@MainActor enum SummaryPreview {
    static func configure(store: AppStore, arguments args: [String]) {
        guard args.contains("--snapshot"), args.contains("--highlights-preview") || args.contains("--evidence-preview"),
              let id = store.selectedID, let index = store.recordings.firstIndex(where: { $0.id == id }) else { return }
        let long = args.contains("--summary-long-preview")
        let firstHeading = long ? "가격과 수요량의 변화율을 비교할 때 부호와 절댓값을 구분해야 하는 이유" : "변화량보다 변화율"
        let firstSummary = long
            ? "수요의 가격탄력성은 가격이 변할 때 수요량이 얼마나 민감하게 반응하는지를 나타냅니다. 단순한 변화량으로 비교하면 상품의 단위와 가격 수준에 따라 결과가 달라지므로, 가격과 수요량의 변화율을 사용합니다. 같은 금액이 올라도 원래 가격이 다른 상품은 소비자가 느끼는 변화의 크기가 다릅니다. 변화율을 기준으로 비교하면 서로 다른 상품의 반응을 같은 기준으로 읽을 수 있습니다."
            : "가격과 수요량의 변화율을 비교해 반응의 민감도를 읽습니다. 단위가 다른 상품도 같은 기준으로 비교할 수 있습니다."
        let items: [[String: Any]] = [
            ["heading": firstHeading, "summary": firstSummary, "signal": "explicit",
             "evidence": [["segmentID": 1, "quote": "여기가 중요합니다. 변화량이 아니라 변화율을 비교해야 해요."],
                          ["segmentID": 2, "quote": "단위가 다른 상품을 비교할 때도 변화율을 써야 합니다."]]],
            ["heading": "부호와 크기 구분하기", "summary": "음의 부호는 가격과 수요량이 반대로 움직인다는 뜻입니다. 탄력성의 크기를 비교할 때는 절댓값을 사용합니다.", "signal": "repeated",
             "evidence": [["segmentID": 3, "quote": "크기를 비교할 때는 절댓값으로 보세요. 다시 말하지만 부호와 크기는 구분해야 합니다."]]]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: items),
              let highlights = try? JSONDecoder().decode([LectureHighlight].self, from: data) else { return }
        store.recordings[index].title = "수요의 가격탄력성"
        store.recordings[index].generatedTitle = "수요의 가격탄력성"
        store.recordings[index].lectureHighlights = args.contains("--summary-empty-preview") ? [] : highlights
        store.recordings[index].segments = [
            .init(id: 1, start: 6, end: 10, text: "여기가 중요합니다. 변화량이 아니라 변화율을 비교해야 해요."),
            .init(id: 2, start: 10, end: 13, text: "단위가 다른 상품을 비교할 때도 변화율을 써야 합니다."),
            .init(id: 3, start: 13, end: 24, text: "크기를 비교할 때는 절댓값으로 보세요. 다시 말하지만 부호와 크기는 구분해야 합니다.")
        ]
    }
}
