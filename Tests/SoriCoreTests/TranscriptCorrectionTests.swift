import XCTest
@testable import SoriCore

final class TranscriptCorrectionTests: XCTestCase {
    func testLongUnicodeTranscriptIsBoundedWithoutMissingOrRenumberingSegments() throws {
        let source = (0..<500).map { index in
            TranscriptSegment(id: index * 3, start: Double(index), end: Double(index) + 0.9,
                              text: "한글 인용 \"과 줄바꿈\n" + String(repeating: "말씀 ", count: index % 20 + 1))
        }
        let chunks = try TranscriptCorrection.chunks(source, maximumBytes: 1200, maximumSegments: 7)
        XCTAssertEqual(chunks.flatMap { $0 }, source)
        XCTAssertGreaterThan(chunks.count, 70)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count, 7)
            XCTAssertLessThanOrEqual(try TranscriptCorrection.input(for: chunk).count, 1200)
        }
    }

    func testOversizedSegmentAndDuplicateSourceIDsFailBeforeSendingPartialData() {
        let large = TranscriptSegment(id: 3, start: 0, end: 2, text: String(repeating: "가", count: 100))
        XCTAssertThrowsError(try TranscriptCorrection.chunks([large], maximumBytes: 64))
        XCTAssertThrowsError(try TranscriptCorrection.chunks([large, large]))
        XCTAssertThrowsError(try TranscriptCorrection.chunks([large], maximumSegments: 0))
    }

    func testCorrectionDataCannotChangeTimesEvenWithUnexpectedTimeFields() throws {
        let source = [TranscriptSegment(id: 42, start: 100.25, end: 103.75, text: "안녕 하세요", originalText: "안녕 하세요")]
        let response = Data(#"{"segments":[{"id":42,"text":"안녕하세요.","start":0,"end":999}]}"#.utf8)
        let result = try TranscriptCorrection.apply(response, to: source)
        XCTAssertEqual(result[0].start, 100.25)
        XCTAssertEqual(result[0].end, 103.75)
        XCTAssertEqual(result[0].originalText, source[0].originalText)
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: TranscriptCorrection.input(for: source)) as? [String: Any])
        let segment = try XCTUnwrap((input["segments"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(segment.keys), ["id", "text"])
    }

    func testSummaryAndExpansionAreRejectedButPunctuationCorrectionsPass() throws {
        let text = String(repeating: "이름과 수치는 그대로 보존해야 합니다. ", count: 15)
        let source = [TranscriptSegment(id: 0, start: 0, end: 50, text: text)]
        for invalid in ["짧은 요약입니다.", String(repeating: text, count: 3)] {
            let response = try JSONSerialization.data(withJSONObject: ["segments": [["id": 0, "text": invalid]]])
            XCTAssertThrowsError(try TranscriptCorrection.apply(response, to: source))
        }
        let valid = try JSONSerialization.data(withJSONObject: ["segments": [["id": 0, "text": text.replacingOccurrences(of: ".", with: "!")]]])
        XCTAssertEqual(try TranscriptCorrection.apply(valid, to: source)[0].id, 0)
    }

    func testCorrectionsFromADifferentChunkCannotBeApplied() throws {
        let source = [TranscriptSegment(id: 48, start: 24, end: 25, text: "예산은 350만 원입니다.")]
        let response = Data(#"{"segments":[{"id":0,"text":"예산은 350만 원입니다."}]}"#.utf8)
        XCTAssertThrowsError(try TranscriptCorrection.apply(response, to: source))
    }
}
