import XCTest
@testable import SoriCore

final class LectureReviewTests: XCTestCase {
    private func segment(_ id: Int, _ text: String) -> TranscriptSegment {
        .init(id: id, start: Double(id * 10), end: Double(id * 10 + 8), text: text)
    }
    private func edit(_ id: Int, _ before: String, _ after: String, _ kind: String = "recognition",
                      evidence: [LectureReview.Evidence] = []) -> LectureReview.Edit {
        .init(segmentID: id, before: before, after: after, kind: kind, evidence: evidence)
    }
    private let noop = Data(#"{"complete":true,"edits":[]}"#.utf8)
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testFormattingKeepsIdentitySourceTimesRepetitionAndCodeSwitching() throws {
        let source = [segment(4, "중요 해요 중요 해요. P와 Q는 그대로예요")]
        let proposal = LectureReview.Proposal(complete: true, edits: [edit(4, "중요 해요 중요 해요", "중요해요 중요해요", "spacing"),
            edit(4, "그대로예요", "그대로예요.", "punctuation")])
        let result = try LectureReview.apply(proposal, to: source)
        XCTAssertEqual(result[0].text, "중요해요 중요해요. P와 Q는 그대로예요.")
        XCTAssertEqual(result[0].originalText, source[0].text)
        XCTAssertEqual(result[0].id, 4)
        XCTAssertEqual(result[0].start, 40)
        XCTAssertEqual(result[0].end, 48)
    }

    func testTermRepairRequiresTwoVerbatimIndependentSources() throws {
        let source = [segment(0, "브레트로즈 체제에서 자본을 통제합니다."),
                      segment(1, "브레턴우즈 체제의 핵심입니다."), segment(2, "브레턴우즈 체제로 돌아갑시다.")]
        let evidence = [LectureReview.Evidence(segmentID: 1, quote: "브레턴우즈 체제"),
                        .init(segmentID: 2, quote: "브레턴우즈 체제")]
        let good = edit(0, "브레트로즈", "브레턴우즈", evidence: evidence)
        XCTAssertEqual(try LectureReview.apply(.init(complete: true, edits: [good]), to: source)[0].text,
                       "브레턴우즈 체제에서 자본을 통제합니다.")
        for bad in [[], Array(evidence.prefix(1)), [evidence[0], evidence[0]],
                    [.init(segmentID: 1, quote: "원문에 없는 브레턴우즈"), evidence[1]]] {
            XCTAssertThrowsError(try LectureReview.apply(.init(complete: true, edits: [edit(0, "브레트로즈", "브레턴우즈", evidence: bad)]), to: source))
        }
    }

    func testNumericalNegationEquationAndLanguageChangesAreRejectedEvenWithEvidence() throws {
        for (before, after) in [("1997년", "1998년"), ("1.5%", "15%"), (".5", "5"), ("-5", "5"),
                                ("십만원", "백만원"), ("아니에요", "맞아요"), ("할 수 없어요", "할 수 있어요"),
                                ("미만", "이상"), ("P=Q", "P<Q"), ("capital", "자본")] {
            let source = [segment(0, before), segment(1, after), segment(2, after)]
            let evidence = [LectureReview.Evidence(segmentID: 1, quote: after), .init(segmentID: 2, quote: after)]
            XCTAssertThrowsError(try LectureReview.apply(.init(complete: true, edits: [edit(0, before, after, evidence: evidence)]), to: source), before)
        }
    }

    func testFormattingCannotRemoveQuestionQuotesOrMathSymbols() throws {
        for (before, after) in [("맞나요?", "맞나요."), ("A → B", "A B"), ("'말'", "말"), ("x/y", "xy")] {
            XCTAssertThrowsError(try LectureReview.apply(.init(complete: true, edits: [edit(0, before, after, "punctuation")]), to: [segment(0, before)]))
        }
    }

    func testMissingWrongAmbiguousAndOverlappingSpansDoNotApply() {
        let source = [segment(0, "같은 말 같은 말입니다.")]
        for edits in [[edit(1, "같은", "같은 ", "spacing")], [edit(0, "없는 말", "없는말", "spacing")],
                      [edit(0, "같은 말", "같은말", "spacing")],
                      [edit(0, "말입니다.", "말 입니다.", "spacing"), edit(0, "말입니다.", "말입니다!", "punctuation")]] {
            XCTAssertThrowsError(try LectureReview.apply(.init(complete: true, edits: edits), to: source))
        }
    }

    func testUnknownFieldsTruncationAndIncompleteRepliesAreRejected() {
        for json in [#"{"complete":true,"edits":[],"answer":"공격"}"#,
                     #"{"complete":true,"edits":[{"segmentID":0,"before":"말","after":"말.","kind":"punctuation","evidence":[],"start":0}]}"#,
                     #"{"complete":true,"edits":["#] {
            XCTAssertThrowsError(try LectureReview.decode(Data(json.utf8)))
        }
        XCTAssertThrowsError(try LectureReview.apply(.init(complete: false, edits: []), to: [segment(0, "전부 검토해야 합니다.")]))
    }

    func testUneditableContextAndRepeatedConceptsCannotBeReplacedGlobally() {
        let source = [segment(0, "통제 경제는 자본 통제와 다릅니다."), segment(1, "통제 경제입니다.")]
        XCTAssertThrowsError(try LectureReview.apply(.init(complete: true, edits: [edit(1, "통제 경제", "통제경제", "spacing")]),
                                                   to: source, editableIDs: [0]))
    }

    func testAllBatchesSeeEndOfLectureAndCacheIsBoundToExactRevision() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = (0..<100).map { segment($0, "강의 문장 \($0) 그대로.") }
        let cache = directory.appendingPathComponent("review.json")
        var covered: [Int] = []
        var calls = 0
        let outcome = try await LectureReview.review(source, cacheURL: cache) { request in
            calls += 1
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: request.input) as? [String: Any])
            let all = try XCTUnwrap(object["source"] as? [String: Any])
            XCTAssertEqual((all["segments"] as? [[String: Any]])?.last?["id"] as? Int, 99)
            let current = try XCTUnwrap(object["editableSegments"] as? [String: Any])
            covered += (current["segments"] as! [[String: Any]]).map { $0["id"] as! Int }
            return self.noop
        }
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(covered, Array(0..<100))
        XCTAssertEqual(outcome.segments, source)
        let cached = try await LectureReview.review(source, cacheURL: cache) { _ in XCTFail("Cache miss"); return self.noop }
        XCTAssertTrue(cached.cached)
        var changed = source; changed[0].text += " 사용자가 고침"
        var refreshed = 0
        _ = try await LectureReview.review(changed, cacheURL: cache) { _ in refreshed += 1; return self.noop }
        XCTAssertEqual(refreshed, 3)
    }

    func testChangingModelInvalidatesFinalAndPartialReviewCaches() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = (0..<50).map { segment($0, "보존할 강의 문장 \($0)") }
        let cache = directory.appendingPathComponent("review.json")
        var calls = 0
        for model in [CodexModel.sol, .luna] {
            let result = try await LectureReview.review(source, cacheURL: cache, selection: model) { _ in
                calls += 1; return self.noop
            }
            XCTAssertFalse(result.cached)
            let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as? [String: Any])
            XCTAssertEqual(receipt["model"] as? String, model.rawValue)
            XCTAssertEqual(receipt["effort"] as? String, "medium")
        }
        XCTAssertEqual(calls, 4)
        let cached = try await LectureReview.review(source, cacheURL: cache, selection: .luna) { _ in
            XCTFail("Same model must reuse its cache"); return self.noop
        }
        XCTAssertTrue(cached.cached)
        XCTAssertEqual(cached.segments, source)
    }

    func testLargeLectureVisitsEveryContextPartAndEverySentence() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = (0..<400).map { segment($0, String(repeating: "긴 강의 문장입니다. ", count: 20) + "끝 \($0)") }
        var contextIDs: [Int] = [], reviewedIDs: [Int] = []
        _ = try await LectureReview.review(source, cacheURL: directory.appendingPathComponent("review.json")) { request in
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: request.input) as? [String: Any])
            if request.instructions == LectureReviewPrompts.context {
                contextIDs += (object["segments"] as! [[String: Any]]).map { $0["id"] as! Int }
                return Data(#"{"complete":true,"terms":[]}"#.utf8)
            }
            XCTAssertNil(object["source"])
            XCTAssertEqual(object["allPartsReviewed"] as? Bool, true)
            let target = object["editableSegments"] as! [String: Any]
            reviewedIDs += (target["segments"] as! [[String: Any]]).map { $0["id"] as! Int }
            return self.noop
        }
        XCTAssertEqual(contextIDs, Array(0..<400))
        XCTAssertEqual(reviewedIDs, Array(0..<400))
    }

    func testLateFailureDoesNotCommitPartialReviewAndInvalidResponsesRetryOnlyOnce() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("review.json")
        let source = (0..<50).map { segment($0, "같은 말을 그대로 보존합니다.") }
        var calls = 0
        do {
            _ = try await LectureReview.review(source, cacheURL: cache) { _ in
                calls += 1
                return calls == 1 ? self.noop : Data(#"{"complete":false,"edits":[]}"#.utf8)
            }
            XCTFail("Should fail")
        } catch {
            XCTAssertEqual(calls, 3)
            XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        }
    }

    func testCancellationAndTransportFailureAreNotRetriedOrCached() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        for error in [CancellationError() as Error, SoriError.message("transport") as Error] {
            var calls = 0
            let cache = directory.appendingPathComponent("review.json")
            do {
                _ = try await LectureReview.review([segment(0, "보존할 원문.")], cacheURL: cache) { _ in calls += 1; throw error }
                XCTFail("Should throw")
            } catch { XCTAssertEqual(calls, 1); XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path)) }
        }
    }

    func testNoPermissionToWriteCannotReportSuccessfulReview() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        do {
            _ = try await LectureReview.review([segment(0, "보존할 원문.")], cacheURL: directory.appendingPathComponent("missing/review.json")) { _ in self.noop }
            XCTFail("Should not report a revision that was never committed")
        } catch { XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("missing/review.json").path)) }
    }

    func testRejectedSentenceKeepsOriginalWhileValidEditsCompleteAndFeedbackExplainsFailure() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = [segment(0, "물건을 사고 팔니까 돈이 오갑니다."), segment(1, "핵심 입니다.")]
        let proposal = LectureReview.Proposal(complete: true, edits: [
            edit(0, "사고 팔니까", "사고파니까", "spacing"), edit(1, "핵심 입니다", "핵심입니다", "spacing")])
        let cache = directory.appendingPathComponent("review.json")
        var calls = 0
        let result = try await LectureReview.review(source, cacheURL: cache) { request in
            calls += 1
            if calls == 2 {
                let payload = try JSONSerialization.jsonObject(with: request.input) as! [String: Any]
                let feedback = payload["validationFeedback"] as! [[String: Any]]
                XCTAssertEqual(feedback[0]["segmentID"] as? Int, 0)
                XCTAssertEqual(feedback[0]["code"] as? String, "not_spacing")
            }
            return try JSONEncoder().encode(proposal)
        }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(result.segments[0], source[0])
        XCTAssertEqual(result.segments[1].text, "핵심입니다.")
        XCTAssertEqual(result.preservedSegments, 1)
        let restored = try await LectureReview.review(source, cacheURL: cache) { _ in XCTFail("Expected cache"); return self.noop }
        XCTAssertEqual(restored.preservedSegments, 1)
        XCTAssertEqual(restored.segments, result.segments)
    }

    func testTransportFailureResumesSavedBatchesWithoutPublishingPartialRevision() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = (0..<50).map { segment($0, "원문 \($0) 그대로.") }
        let cache = directory.appendingPathComponent("review.json")
        var calls = 0
        do {
            _ = try await LectureReview.review(source, cacheURL: cache) { _ in
                calls += 1
                if calls == 2 { throw SoriError.message("offline") }
                return self.noop
            }
            XCTFail("Expected offline error")
        } catch { XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path)) }
        calls = 0
        let result = try await LectureReview.review(source, cacheURL: cache) { request in
            calls += 1
            let payload = try JSONSerialization.jsonObject(with: request.input) as! [String: Any]
            let target = payload["editableSegments"] as! [String: Any]
            XCTAssertEqual((target["segments"] as! [[String: Any]]).first!["id"] as? Int, 48)
            return self.noop
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(result.segments, source)
    }
}
