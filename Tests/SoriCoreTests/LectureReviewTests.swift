import XCTest
import DoongdoongAI
@testable import SoriCore

final class LectureReviewTests: XCTestCase {
    func testProviderAndEffortHaveSeparateCachesAndRetriesDoNotAdvanceProgress() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = [segment(0, "이 문장을 보존합니다.")]
        let cache = directory.appendingPathComponent("review.json")
        let identities = [TextProviderIdentity(provider: "codex", model: "test", reasoningEffort: "medium"),
                          .init(provider: "another-provider", model: "test", reasoningEffort: "medium"),
                          .init(provider: "another-provider", model: "test", reasoningEffort: "high")]
        for identity in identities {
            var calls = 0
            var counts: [Int] = []
            let result = try await LectureReview.review(source, cacheURL: cache, identity: identity,
                onProgress: { counts.append($0.completed) }) { _ in
                    calls += 1
                    return calls == 1 ? Data("{}".utf8) : self.noop
                }
            XCTAssertFalse(result.cached)
            XCTAssertEqual(calls, 2)
            XCTAssertEqual(counts, [0, 0, 1])
        }
        let cached = try await LectureReview.review(source, cacheURL: cache, identity: identities.last!) { _ in
            XCTFail("The same provider identity should reuse validated work"); return self.noop
        }
        XCTAssertTrue(cached.cached)
    }
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

    func testContextualRepairAllowsRareTermsButAnyRecordedEvidenceMustBeVerbatim() throws {
        let source = [segment(0, "브레트로즈 체제에서 자본을 통제합니다."),
                      segment(1, "브레턴우즈 체제의 핵심입니다."), segment(2, "브레턴우즈 체제로 돌아갑시다.")]
        let evidence = [LectureReview.Evidence(segmentID: 1, quote: "브레턴우즈 체제"),
                        .init(segmentID: 2, quote: "브레턴우즈 체제")]
        let good = edit(0, "브레트로즈", "브레턴우즈", evidence: evidence)
        XCTAssertEqual(try LectureReview.apply(.init(complete: true, edits: [good]), to: source)[0].text,
                       "브레턴우즈 체제에서 자본을 통제합니다.")
        for supported in [Array(evidence.prefix(1))] {
            XCTAssertNoThrow(try LectureReview.apply(.init(complete: true, edits: [edit(0, "브레트로즈", "브레턴우즈", evidence: supported)]), to: source))
        }
        for bad in [[evidence[0], evidence[0]],
                    [.init(segmentID: 1, quote: "원문에 없는 브레턴우즈"), evidence[1]]] {
            XCTAssertThrowsError(try LectureReview.apply(.init(complete: true, edits: [edit(0, "브레트로즈", "브레턴우즈", evidence: bad)]), to: source))
        }
    }

    func testNumericalNegationEquationAndLanguageChangesAreRejectedEvenWithEvidence() throws {
        for (before, after) in [("1997년", "1998년"), ("1.5%", "15%"), (".5", "5"), ("-5", "5"),
                                ("십만원", "백만원"), ("가격은십만원", "가격은백만원"), ("삼", "사"),
                                ("50명", "50년"), ("8개", "8배"), ("1억 달러", "1억 원"),
                                ("아니에요", "맞아요"), ("할 수 없어요", "할 수 있어요"),
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

    func testWholeLectureUsesOneRequestAndCacheIsBoundToExactRevision() async throws {
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
            covered += try XCTUnwrap(object["editableIDs"] as? [Int])
            return self.noop
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(covered, Array(0..<100))
        XCTAssertEqual(outcome.segments, source)
        let cached = try await LectureReview.review(source, cacheURL: cache) { _ in XCTFail("Cache miss"); return self.noop }
        XCTAssertTrue(cached.cached)
        var changed = source; changed[0].text += " 사용자가 고침"
        var refreshed = 0
        _ = try await LectureReview.review(changed, cacheURL: cache) { _ in refreshed += 1; return self.noop }
        XCTAssertEqual(refreshed, 1)
    }

    func testChangingModelInvalidatesFinalAndPartialReviewCaches() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = (0..<50).map { segment($0, "보존할 강의 문장 \($0)") }
        let cache = directory.appendingPathComponent("review.json")
        var calls = 0
        for model in ["gpt-6.1-sol", "gpt-6-luna"] {
            let result = try await LectureReview.review(source, cacheURL: cache, identity: .init(provider: "codex", model: model, reasoningEffort: "medium")) { _ in
                calls += 1; return self.noop
            }
            XCTAssertFalse(result.cached)
            let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as? [String: Any])
            XCTAssertEqual(receipt["model"] as? String, model)
            XCTAssertEqual(receipt["effort"] as? String, "medium")
        }
        XCTAssertEqual(calls, 2)
        let cached = try await LectureReview.review(source, cacheURL: cache, identity: .init(provider: "codex", model: "gpt-6-luna", reasoningEffort: "medium")) { _ in
            XCTFail("Same model must reuse its cache"); return self.noop
        }
        XCTAssertTrue(cached.cached)
        XCTAssertEqual(cached.segments, source)
    }

    func testLargeLectureStillSendsAllTextInOneRequest() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = (0..<400).map { segment($0, String(repeating: "Lecture text ", count: 40) + "end \($0)") }
        var calls = 0
        _ = try await LectureReview.review(source, cacheURL: directory.appendingPathComponent("review.json")) { request in
            calls += 1
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: request.input) as? [String: Any])
            let full = try XCTUnwrap(object["source"] as? [String: Any])
            XCTAssertEqual((full["segments"] as? [[String: Any]])?.count, 400)
            XCTAssertEqual(object["editableIDs"] as? [Int], Array(0..<400))
            return self.noop
        }
        XCTAssertEqual(calls, 1)
    }

    func testLateFailureDoesNotPublishPartialReviewAndInvalidResponsesRetryOnlyOnce() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("review.json")
        let source = (0..<50).map { segment($0, "Preserve sentence \($0).") }
        var calls = 0
        do {
            _ = try await LectureReview.review(source, cacheURL: cache) { _ in
                calls += 1
                if calls == 1 { throw TextGenerationError.capacityExceeded }
                return calls == 2 ? self.noop : Data("{}".utf8)
            }
            XCTFail("Should fail")
        } catch {
            XCTAssertEqual(calls, 4)
            XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        }
    }

    func testCapacityFallbackRecursivelyHalvesWithoutMissingOrDuplicatingIDs() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = (0..<16).map { segment($0, "Preserve sentence \($0).") }
        var requests: [[Int]] = [], covered: [Int] = [], progress: [Int] = []
        let result = try await LectureReview.review(source, cacheURL: directory.appendingPathComponent("review.json"),
            onProgress: { progress.append($0.completed) }) { request in
            let payload = try JSONSerialization.jsonObject(with: request.input) as! [String: Any]
            let ids = payload["editableIDs"] as! [Int]; requests.append(ids)
            if ids.count > 4 { throw TextGenerationError.capacityExceeded }
            covered += ids
            return self.noop
        }
        XCTAssertEqual(requests.first, Array(0..<16))
        XCTAssertEqual(requests.count, 7)
        XCTAssertEqual(covered, Array(0..<16))
        XCTAssertEqual(progress, progress.sorted())
        XCTAssertEqual(progress.last, 16)
        XCTAssertEqual(result.segments, source)
    }

    func testLocalInputLimitHalvesAndSingleSentenceCapacityFailureStops() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = (0..<200).map { segment($0, String(repeating: "a", count: 3000)) }
        var covered: [Int] = [], calls = 0
        _ = try await LectureReview.review(source, cacheURL: directory.appendingPathComponent("review.json")) { request in
            calls += 1; XCTAssertLessThanOrEqual(request.input.count, 500_000)
            let payload = try JSONSerialization.jsonObject(with: request.input) as! [String: Any]
            covered += payload["editableIDs"] as! [Int]
            return self.noop
        }
        XCTAssertEqual(calls, 2); XCTAssertEqual(covered, Array(0..<200))
        calls = 0
        do {
            _ = try await LectureReview.review([segment(0, "one")], cacheURL: directory.appendingPathComponent("single.json")) { _ in
                calls += 1; throw TextGenerationError.capacityExceeded
            }
            XCTFail("Must stop at an indivisible sentence")
        } catch { XCTAssertEqual(calls, 1) }
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

    func testRejectedSentenceKeepsOriginalWithoutRegeneratingValidEdits() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = [segment(0, "국제수준은 그대로입니다."), segment(1, "핵심 입니다.")]
        let proposal = LectureReview.EditPlan(complete: true, edits: [
            .init(ids: [0], before: "국제수준", after: "국제수지"),
            .init(ids: [1], before: "핵심 입니다", after: "핵심입니다")])
        let cache = directory.appendingPathComponent("review.json")
        var calls = 0
        let result = try await LectureReview.review(source, cacheURL: cache) { request in
            calls += 1
            return try JSONEncoder().encode(proposal)
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(result.segments[0], source[0])
        XCTAssertEqual(result.segments[1].text, "핵심입니다.")
        XCTAssertEqual(result.preservedSegments, 1)
        let restored = try await LectureReview.review(source, cacheURL: cache) { _ in XCTFail("Expected cache"); return self.noop }
        XCTAssertEqual(restored.preservedSegments, 1)
        XCTAssertEqual(restored.segments, result.segments)
    }

    func testGroupedPlanChangesOnlyExplicitOccurrencesAndInfersEditKinds() throws {
        let source = [segment(0, "금본이제입니다."), segment(1, "금본이제입니다."),
                      segment(2, "금본이제입니다."), segment(3, "핵심 입니다.")]
        let plan = LectureReview.EditPlan(complete: true, edits: [
            .init(ids: [0, 2], before: "금본이제", after: "금본위제"),
            .init(ids: [3], before: "핵심 입니다", after: "핵심입니다")])
        let proposal = try LectureReview.decodePlan(JSONEncoder().encode(plan), source: source)
        XCTAssertEqual(proposal.edits.count, 3)
        XCTAssertEqual(proposal.edits.map(\.kind), ["recognition", "recognition", "spacing"])
        let revised = try LectureReview.apply(proposal, to: source)
        XCTAssertEqual(revised[0].text, "금본위제입니다.")
        XCTAssertEqual(revised[1], source[1])
        XCTAssertEqual(revised[2].text, "금본위제입니다.")
        XCTAssertEqual(revised[3].text, "핵심입니다.")
    }

    func testMalformedDuplicateAndExcessivePlansFailBeforeExpansion() throws {
        let source = [segment(0, "핵심 입니다.")]
        for json in [#"{"complete":true,"edits":[{"ids":[0,0],"before":"핵심 입니다","after":"핵심입니다"}]}"#,
                     #"{"complete":true,"edits":[{"ids":[],"before":"핵심 입니다","after":"핵심입니다"}]}"#,
                     #"{"complete":true,"edits":[{"ids":[0],"before":"핵심 입니다","after":"핵심입니다","reason":"extra"}]}"#] {
            XCTAssertThrowsError(try LectureReview.decodePlan(Data(json.utf8), source: source))
        }
        let plan = LectureReview.EditPlan(complete: true, edits: [.init(ids: Array(0...4096), before: "a", after: "b")])
        XCTAssertThrowsError(try LectureReview.decodePlan(JSONEncoder().encode(plan), source: source))
    }

    func testParticleAgreementAndHangulWordSuffixAreNotConfusedWithNumbers() throws {
        let source = [segment(0, "국제수준은 변하지 않아요."), segment(1, "트랜스 내셔만이라고 합니다.")]
        XCTAssertThrowsError(try LectureReview.apply(.init(complete: true, edits: [edit(0, "국제수준", "국제수지")]), to: source))
        XCTAssertEqual(try LectureReview.apply(.init(complete: true, edits: [edit(0, "국제수준은", "국제수지는")]), to: source)[0].text,
                       "국제수지는 변하지 않아요.")
        XCTAssertNoThrow(try LectureReview.apply(.init(complete: true, edits: [edit(1, "트랜스 내셔만", "트랜스 내셔널")]), to: source))
    }

    func testSharedVerbEndingsAndUnchangedWordsDoNotJustifyNewPredicates() throws {
        let source = [segment(0, "금본이제의 특징입니다."), segment(1, "지금도 환율을 말하고 있어요.")]
        XCTAssertEqual(try LectureReview.apply(.init(complete: true, edits: [edit(0, "금본이제", "금본위제")]), to: source)[0].text,
                       "금본위제의 특징입니다.")
        XCTAssertThrowsError(try LectureReview.apply(.init(complete: true, edits: [edit(1, "말하고", "변하고")]), to: source))
        for (before, after) in [("말하고 있어요", "변하고 있어요"), ("공부하는 중이에요", "거래하는 중이에요")] {
            XCTAssertThrowsError(try LectureReview.apply(.init(complete: true, edits: [edit(0, before, after)]),
                                                       to: [segment(0, before)]))
        }
        XCTAssertNoThrow(try LectureReview.apply(.init(complete: true, edits: [edit(0, "설멍하는 중입니다", "설명하는 중입니다")]),
                                                to: [segment(0, "설멍하는 중입니다")]))
    }

    func testInvalidUnitAndOverlappingEditsDoNotEraseIndependentRepairInSameSentence() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = [segment(0, "50명이 금갈라 태환을 설명합니다."),
                      segment(1, "금달러 태환입니다."), segment(2, "금달러 태환을 중단했어요.")]
        let plan = LectureReview.EditPlan(complete: true, edits: [
            .init(ids: [0], before: "50명", after: "50년"),
            .init(ids: [0], before: "금갈라", after: "금달러"),
            .init(ids: [0], before: "설명합니다.", after: "설명합니다!"),
            .init(ids: [0], before: "설명합니다.", after: "설명 합니다.")])
        var calls = 0
        let result = try await LectureReview.review(source, cacheURL: directory.appendingPathComponent("review.json")) { _ in
            calls += 1; return try JSONEncoder().encode(plan)
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(result.segments[0].text, "50명이 금달러 태환을 설명합니다.")
        XCTAssertEqual(result.preservedSegments, 1)
        XCTAssertEqual(result.edits, 1)
    }

    func testTransportFailureResumesSavedBatchesWithoutPublishingPartialRevision() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = (0..<50).map { segment($0, "원문 \($0) 그대로.") }
        let cache = directory.appendingPathComponent("review.json")
        var calls = 0
        do {
            _ = try await LectureReview.review(source, cacheURL: cache) { _ in
                calls += 1
                if calls == 1 { throw TextGenerationError.capacityExceeded }
                if calls == 3 { throw SoriError.message("offline") }
                return self.noop
            }
            XCTFail("Expected offline error")
        } catch { XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path)) }
        calls = 0
        let result = try await LectureReview.review(source, cacheURL: cache) { request in
            calls += 1
            let payload = try JSONSerialization.jsonObject(with: request.input) as! [String: Any]
            let ids = payload["editableIDs"] as! [Int]
            XCTAssertEqual(ids.first, 25)
            XCTAssertEqual(ids.last, 49)
            return self.noop
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(result.segments, source)
    }
}
