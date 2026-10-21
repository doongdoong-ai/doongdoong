import XCTest
import SoriCore
@testable import SoriSpeech

final class AlignmentTests: XCTestCase {
    func testBundledAlignmentHelperExists() {
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: TranscriptAlignment.helper.path))
    }
    private func document(_ segments: [TranscriptSegment], text: String = "첫 문장. 다음 문장.") throws -> Data {
        let values = try JSONSerialization.jsonObject(with: JSONEncoder().encode(segments))
        return try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "method": "mms-ctc-forced-alignment", "text": text, "duration": 10, "segments": values])
    }
    func testAlignmentPreservesSilenceAndExactSourceText() throws {
        let segments = [TranscriptSegment(id: 0, start: 1, end: 3, text: "첫 문장."), TranscriptSegment(id: 1, start: 7, end: 9, text: "다음 문장.")]
        let decoded = try TranscriptAlignment.decode(document(segments), text: "첫 문장. 다음 문장.", duration: 10)
        XCTAssertEqual(decoded, segments)
        XCTAssertNil(Transcript.activeID(at: 5, in: decoded))
        XCTAssertEqual(Transcript.activeID(at: 7.5, in: decoded), 1)
    }
    func testOmittedTextAndOverlappingOrOutOfBoundsTimesAreRejected() throws {
        let good = [TranscriptSegment(id: 0, start: 1, end: 3, text: "첫 문장."), TranscriptSegment(id: 1, start: 7, end: 9, text: "다음 문장.")]
        for invalid in [Array(good.prefix(1)), [good[0], TranscriptSegment(id: 1, start: 2, end: 9, text: "다음 문장.")],
                        [good[0], TranscriptSegment(id: 1, start: 7, end: 11, text: "다음 문장.")]] {
            XCTAssertThrowsError(try TranscriptAlignment.decode(document(invalid), text: "첫 문장. 다음 문장.", duration: 10))
        }
        XCTAssertThrowsError(try TranscriptAlignment.decode(document(good), text: "잘못된 원문", duration: 10))
    }

    func testApproximatePositionIsPreservedButNeverDrivesFollowAlong() throws {
        var first = TranscriptSegment(id: 0, start: 1, end: 3, text: "첫 문장.")
        first.timingQuality = "aligned"
        var second = TranscriptSegment(id: 1, start: 4, end: 7, text: "다음 문장.")
        second.timingQuality = "approximate"
        var object = try JSONSerialization.jsonObject(with: document([first, second])) as! [String: Any]
        object["schemaVersion"] = 2
        object["reviewRanges"] = [["start": 8, "end": 10, "reason": "unmatched_audio"]]
        let report = try TranscriptAlignment.decodeReport(JSONSerialization.data(withJSONObject: object), text: "첫 문장. 다음 문장.", duration: 10)
        XCTAssertEqual(report.segments, [first, second])
        XCTAssertEqual(report.reviewRanges, [.init(start: 8, end: 10)])
        XCTAssertEqual(Transcript.activeID(at: 2, in: report.segments), 0)
        XCTAssertNil(Transcript.activeID(at: 5, in: report.segments))
        object["reviewRanges"] = [["start": 8, "end": 12, "reason": "unmatched_audio"]]
        XCTAssertThrowsError(try TranscriptAlignment.decodeReport(JSONSerialization.data(withJSONObject: object), text: "첫 문장. 다음 문장.", duration: 10))
    }
}
