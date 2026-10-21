import XCTest
import SoriCore
@testable import SoriSpeech

final class SpeechRecoveryTests: XCTestCase {
    func testEnglishOnlyRecoveryOfKoreanGapRequiresManualReview() {
        XCTAssertFalse(SpeechRecovery.acceptsLanguage("Good.", hint: "ko"))
        XCTAssertFalse(SpeechRecovery.acceptsLanguage("Transfer.", hint: "ko"))
        XCTAssertFalse(SpeechRecovery.acceptsLanguage("...", hint: "ko"))
        XCTAssertTrue(SpeechRecovery.acceptsLanguage("이전, transfer라는 뜻이에요.", hint: "ko"))
        XCTAssertTrue(SpeechRecovery.acceptsLanguage("Good.", hint: "en"))
        XCTAssertTrue(SpeechRecovery.acceptsLanguage("Transfer.", hint: "auto"))
    }

    func testShortRecoveryUsesDominantKoreanContextWithoutOverridingExplicitLanguage() {
        let korean = [segment(0, 10, "자본 통제는 단기 금융의 국제 이동을 통제하는 정책입니다. 고정환율제와 함께 설명합니다.")]
        XCTAssertEqual(SpeechRecovery.recoveryLanguage(requested: "auto", source: korean), "ko")
        XCTAssertEqual(SpeechRecovery.recoveryLanguage(requested: "en", source: korean), "en")
        XCTAssertEqual(SpeechRecovery.recoveryLanguage(requested: "auto", source: [segment(0, 2, "Hello world")]), "auto")
        XCTAssertEqual(SpeechRecovery.recoveryLanguage(requested: "auto", source: [segment(0, 2, "그지")]), "auto")
    }

    private func segment(_ start: Double, _ end: Double, _ text: String, quality: String = "aligned") -> TranscriptSegment {
        var value = TranscriptSegment(id: 0, start: start, end: end, text: text)
        value.timingQuality = quality
        return value
    }

    func testRecoveryAddsOnlyIndependentlyAlignedTextInsideItsOriginalGap() throws {
        let first = segment(0, 2, "첫 문장"), last = segment(8, 10, "끝 문장")
        let original = TranscriptAlignment.Report(segments: [first, last], reviewRanges: [.init(start: 2, end: 8)])
        let candidate = SpeechRecovery.Candidate(startFrame: 32000, endFrame: 128000, text: "빠진 말")
        let found = segment(3, 7, "빠진 말")
        let result = try SpeechRecovery.merge(original, candidates: [candidate], aligned: .init(segments: [found], reviewRanges: []))
        XCTAssertEqual(result.segments.map(\.text), ["첫 문장", "빠진 말", "끝 문장"])
        XCTAssertEqual(result.segments.map(\.id), [0, 1, 2])
        XCTAssertEqual(result.segments[0].start, first.start)
        XCTAssertEqual(result.segments[2].end, last.end)
        XCTAssertTrue(result.reviewRanges.isEmpty)
    }

    func testUncertainIncompleteOrOverlappingRecoveryNeverReplacesSource() throws {
        let source = [segment(0, 2, "반복"), segment(8, 10, "반복")]
        let original = TranscriptAlignment.Report(segments: source, reviewRanges: [.init(start: 2, end: 8)])
        let candidate = SpeechRecovery.Candidate(startFrame: 32000, endFrame: 128000, text: "새 문장")
        for probe in [segment(3, 7, "새 문장", quality: "approximate"), segment(1, 4, "새 문장"), segment(3, 7, "다른 문장")] {
            let result = try SpeechRecovery.merge(original, candidates: [candidate], aligned: .init(segments: [probe], reviewRanges: []))
            XCTAssertEqual(result.segments.map(\.text), source.map(\.text))
            XCTAssertEqual(result.reviewRanges, original.reviewRanges)
        }
        let result = try SpeechRecovery.merge(original, candidates: [candidate], aligned: .init(segments: [segment(3, 5, "새 문장")], reviewRanges: [.init(start: 5, end: 8)]))
        XCTAssertEqual(result.segments.map(\.text), source.map(\.text))
        XCTAssertEqual(result.reviewRanges, original.reviewRanges)
    }
}
