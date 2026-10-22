import XCTest
@testable import SoriCore

final class TranscriptTests: XCTestCase {
    let segments = [
        TranscriptSegment(id: 0, start: 1, end: 3, text: "첫 번째 문장입니다."),
        TranscriptSegment(id: 1, start: 5, end: 7.125, text: "두 번째 문장입니다.")
    ]

    func testPlaybackBoundariesAndSilence() {
        XCTAssertNil(Transcript.activeID(at: 0, in: segments))
        XCTAssertEqual(Transcript.activeID(at: 1, in: segments), 0)
        XCTAssertEqual(Transcript.activeID(at: 2.999, in: segments), 0)
        XCTAssertNil(Transcript.activeID(at: 3, in: segments))
        XCTAssertNil(Transcript.activeID(at: 4, in: segments))
        XCTAssertEqual(Transcript.activeID(at: 5, in: segments), 1)
        XCTAssertNil(Transcript.activeID(at: 7.125, in: segments))
        XCTAssertNil(Transcript.activeID(at: 10, in: []))
    }

    func testLegacyTranscriptClampsOverlapsAndAudioEnd() throws {
        let json = #"{"transcription":[{"offsets":{"from":-100,"to":2000},"text":" 시작 "},{"offsets":{"from":1900,"to":4000},"text":"두 번째"},{"offsets":{"from":5000,"to":7000},"text":"파일 밖"},{"offsets":{"from":7000,"to":7000},"text":""}]}"#
        let parsed = try Transcript.parseLegacyTranscript(Data(json.utf8), duration: 3.5)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].start, 0)
        XCTAssertEqual(parsed[0].text, "시작")
        XCTAssertEqual(parsed[1].start, 2)
        XCTAssertEqual(parsed[1].end, 3.5)
    }

    func testLegacyTranscriptIncompleteKoreanUTF8DoesNotLoseTheLecture() throws {
        var data = Data(#"{"transcription":[{"offsets":{"from":1406610,"to":1407780},"text":"앞부분 "#.utf8)
        // A Korean syllable cut after two bytes, as reproduced in CLI output.
        data.append(contentsOf: [0xEB, 0xA3])
        data.append(Data(#" 뒤 문장"},{"offsets":{"from":4000000,"to":4002000},"text":"강의 끝"}]}"#.utf8))
        let parsed = try Transcript.parseLegacyTranscript(data, duration: 4100)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].text, "앞부분 � 뒤 문장")
        XCTAssertEqual(parsed[0].originalText, parsed[0].text)
        XCTAssertEqual(parsed[0].start, 1406.610)
        XCTAssertEqual(parsed[1].end, 4002)
        XCTAssertEqual(parsed[1].text, "강의 끝")
    }

    func testInvalidUTF8InUnusedTokenDoesNotDamageValidSegmentText() throws {
        var data = Data(#"{"transcription":[{"offsets":{"from":0,"to":2000},"text":"정상 문장","tokens":[{"text":""#.utf8)
        data.append(0xEB)
        data.append(Data(#""}]}]}"#.utf8))
        let parsed = try Transcript.parseLegacyTranscript(data, duration: 3)
        XCTAssertEqual(parsed.map(\.text), ["정상 문장"])
        // Encoding repair must not accept truncated or structurally malformed JSON.
        XCTAssertThrowsError(try Transcript.parseLegacyTranscript(data.dropLast(), duration: 3))
    }

    func testCorrectionsPreserveIdentityTimingAndOriginalText() throws {
        let json = #"{"segments":[{"id":1,"text":"두 번째 문장!"},{"id":0,"text":"첫 번째 문장!"}]}"#
        let result = try Transcript.applyCorrections(Data(json.utf8), to: segments)
        XCTAssertEqual(result.map(\.id), [0, 1])
        XCTAssertEqual(result.map(\.start), segments.map(\.start))
        XCTAssertEqual(result.map(\.end), segments.map(\.end))
        XCTAssertEqual(result.map(\.originalText), segments.map(\.text))
        XCTAssertEqual(result[0].text, "첫 번째 문장!")
    }

    func testIncompleteAndDuplicateCodexResponsesAreRejected() {
        for json in [
            #"{"segments":[{"id":0,"text":"하나"}]}"#,
            #"{"segments":[{"id":0,"text":"하나"},{"id":0,"text":"둘"}]}"#,
            #"{"segments":[{"id":0,"text":"하나"},{"id":1,"text":"  "}]}"#,
            #"{"segments":[{"id":0,"text":"하나"},{"id":5,"text":"둘"}]}"#
        ] { XCTAssertThrowsError(try Transcript.applyCorrections(Data(json.utf8), to: segments)) }
    }

    func testSubtitleMillisecondAccuracyAndHourFormatting() {
        let output = Transcript.srt(segments)
        XCTAssertTrue(output.contains("00:00:05,000 --> 00:00:07,125"))
        XCTAssertTrue(output.contains("1\n00:00:01,000"))
        XCTAssertEqual(TimeText.srt(3661.999), "01:01:01,999")
        XCTAssertEqual(TimeText.clock(3661), "1:01:01")
        XCTAssertEqual(TimeText.clock(-10), "00:00")
        XCTAssertEqual(TimeText.clock(.nan), "00:00")
    }

    func testInvalidAndExtremeTimeValuesNeverTrapOrActivateLyrics() throws {
        XCTAssertEqual(TimeText.clock(.greatestFiniteMagnitude), "596523:14:07")
        XCTAssertEqual(TimeText.srt(.greatestFiniteMagnitude), "596523:14:07,000")
        XCTAssertEqual(TimeText.srt(.infinity), "00:00:00,000")
        XCTAssertNil(Transcript.activeID(at: .nan, in: segments))
        XCTAssertNil(Transcript.activeID(at: .infinity, in: segments))
        let json = Data(#"{"transcription":[]}"#.utf8)
        for duration in [0, -1, .nan, .infinity] {
            XCTAssertThrowsError(try Transcript.parseLegacyTranscript(json, duration: duration))
        }
    }

    func testDuplicateSourceIDsRejectCorrectionsInsteadOfTrapping() {
        let corrupt = [segments[0], segments[0]]
        let data = Data(#"{"segments":[{"id":0,"text":"첫째"},{"id":0,"text":"둘째"}]}"#.utf8)
        XCTAssertThrowsError(try Transcript.applyCorrections(data, to: corrupt))
    }
    func testAppleAndLegacyTimingRemainClickable() {
        for quality in ["apple-speech", "whisper", "aligned"] {
            var segment = TranscriptSegment(id: 1, start: 1, end: 3, text: "강의")
            segment.timingQuality = quality
            XCTAssertTrue(segment.hasReliableTiming)
            XCTAssertEqual(Transcript.activeID(at: 2, in: [segment]), 1)
        }
    }

}
