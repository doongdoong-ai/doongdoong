import Foundation
import XCTest
import SoriCore
import DoongdoongTranscription
import DoongdoongAI
@testable import SoriApp

private actor StubRecognizer: SpeechRecognizer {
    var calls = 0
    let invalid: Bool
    init(invalid: Bool = false) { self.invalid = invalid }
    func transcribe(wave: Data, configuration: SpeechConfiguration) async throws -> [SpeechSegment] {
        calls += 1
        return [.init(start: 0, end: invalid ? 100 : 1, text: "원문 그대로 보관합니다.")]
    }
}

@MainActor private final class StubTextProvider: TextGenerationProvider {
    let identity: TextProviderIdentity
    var requests = 0
    let invalid: Bool
    var invalidAnalysis = false
    var willGenerate: ((StructuredTextRequest) -> Void)?
    init(invalid: Bool = false, identity: TextProviderIdentity = .init(provider: "test-vendor", model: "test-model", reasoningEffort: "test-effort")) {
        self.invalid = invalid; self.identity = identity
    }
    func checkConnection() async throws {}
    func generate(_ request: StructuredTextRequest) async throws -> Data {
        requests += 1
        willGenerate?(request)
        if invalid { return Data("{}".utf8) }
        if request.instructions == LectureReviewPrompts.correction {
            return Data(#"{"complete":true,"edits":[]}"#.utf8)
        }
        if request.instructions.hasPrefix("Combine analyses") {
            return Data(#"{"title":"원문 보관","selectedIDs":[]}"#.utf8)
        }
        if invalidAnalysis { return Data("{}".utf8) }
        return Data(#"{"title":"원문 보관","synopsis":"원문을 그대로 보관한다는 설명입니다.","highlights":[]}"#.utf8)
    }
}

final class TranscriptionPipelineTests: XCTestCase {
    @MainActor func testLongLectureSummaryOnlyCompletesAfterSynthesis() async throws {
        let (root, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let segments = (0..<4).map { TranscriptSegment(id: $0, start: Double($0), end: Double($0 + 1),
                                                       text: String(repeating: "강의 내용입니다. ", count: 3000)) }
        var progress: [ProcessingProgress] = []
        let provider = StubTextProvider()
        _ = try await TranscriptionPipeline.organize(segments: segments, directory: root,
                                                    provider: provider, onProgress: { progress.append($0) })
        XCTAssertGreaterThan(provider.requests, 2)
        XCTAssertTrue(progress.filter { $0.stage == .analysis }.allSatisfy { ($0.fraction ?? 0) < 1 })
        XCTAssertEqual(progress.last?.stage, .synthesis)
        XCTAssertEqual(progress.last?.fraction, 1)
        let fractions = progress.compactMap(\.fraction)
        XCTAssertEqual(fractions, fractions.sorted())
    }

    @MainActor func testIndependentProviderProcessesTextWithMeasuredStageProgress() async throws {
        let (root, audio, configuration) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try Data(contentsOf: audio)
        let provider = StubTextProvider()
        var progress: [ProcessingProgress] = []
        var published = false
        provider.willGenerate = { request in
            XCTAssertEqual(published, request.instructions != LectureReviewPrompts.correction)
        }
        let result = try await TranscriptionPipeline.transcribe(audio: audio, directory: root, duration: 1,
            configuration: configuration, recognizer: StubRecognizer(), provider: provider, onProgress: { progress.append($0) },
            onReviewed: { _ in published = true })
        guard case .transcribed(let segments, let lecture, let warning, _) = result else { return XCTFail("Missing transcript") }
        XCTAssertEqual(provider.requests, 2)
        XCTAssertEqual(segments.first?.originalText, "원문 그대로 보관합니다.")
        XCTAssertEqual(segments.first?.start, 0); XCTAssertEqual(segments.last?.end, 1)
        XCTAssertEqual(lecture?.title, "원문 보관"); XCTAssertNil(warning)
        XCTAssertEqual(progress.last(where: { $0.stage == .transcription })?.fraction, 1)
        XCTAssertEqual(progress.last(where: { $0.stage == .correction })?.fraction, 1)
        XCTAssertNil(progress.first(where: { $0.stage == .analysis })?.fraction)
        XCTAssertEqual(progress.last(where: { $0.stage == .analysis })?.fraction, 1)
        XCTAssertEqual(try Data(contentsOf: audio), original)
        let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("final-review.json"))) as? [String: Any])
        XCTAssertEqual(receipt["provider"] as? String, "test-vendor")
    }

    @MainActor func testInvalidProviderResultPreservesSourceWithoutFalseCompletion() async throws {
        let (root, audio, configuration) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var progress: [ProcessingProgress] = []
        do {
        _ = try await TranscriptionPipeline.transcribe(audio: audio, directory: root, duration: 1,
            configuration: configuration, recognizer: StubRecognizer(), provider: StubTextProvider(invalid: true), onProgress: { progress.append($0) })
            XCTFail("Unreviewed transcript must never be returned")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("local-asr-original.json").path))
            XCTAssertTrue(progress.last(where: { $0.stage == .correction })?.issue == true)
            XCTAssertFalse(progress.contains { $0.stage == .analysis || ($0.stage == .correction && $0.fraction == 1) })
        }
    }

    @MainActor func testChangingProviderReusesAudioButNotAnotherProvidersCorrection() async throws {
        let (root, audio, configuration) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let recognizer = StubRecognizer()
        // Keep model and effort identical so only the vendor distinguishes caches.
        let first = StubTextProvider(identity: .init(provider: "vendor-a", model: "model", reasoningEffort: "medium"))
        let second = StubTextProvider(identity: .init(provider: "vendor-b", model: "model", reasoningEffort: "medium"))
        for provider in [first, second, second] {
            let result = try await TranscriptionPipeline.transcribe(audio: audio, directory: root, duration: 1,
                configuration: configuration, recognizer: recognizer, provider: provider)
            guard case .transcribed(let segments, let lecture, _, _) = result else { return XCTFail("Missing transcript") }
            XCTAssertEqual(segments.first?.originalText, "원문 그대로 보관합니다.")
            XCTAssertEqual(segments.first?.start, 0); XCTAssertEqual(segments.last?.end, 1)
            XCTAssertNotNil(lecture)
            let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("final-review.json"))) as? [String: Any])
            XCTAssertEqual(receipt["provider"] as? String, provider.identity.provider)
        }
        XCTAssertEqual(first.requests, 2, "First vendor corrects and summarizes")
        XCTAssertEqual(second.requests, 3, "Second vendor corrects once and summarizes on each run")
        let calls = await recognizer.calls
        XCTAssertEqual(calls, 1, "Provider changes must not repeat speech recognition")
    }
    @MainActor private func fixture() throws -> (URL, URL, SpeechConfiguration) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("doongdoong-pipeline-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = root.appendingPathComponent("audio.wav")
        var data = Data("RIFF".utf8)
        func u32(_ v: UInt32) { var v = v.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var v = v.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        u32(32036); data.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
        data.append(Data("data".utf8)); u32(32000)
        for index in 0..<16000 { u16(UInt16(bitPattern: Int16(sin(Double(index) * 0.1) * 10000))) }
        try data.write(to: audio)
        let config = SpeechConfiguration()
        return (root, audio, config)
    }

    @MainActor func testInvalidTimestampsAreNotPublishedAndOriginalAudioIsUntouched() async throws {
        let (root, audio, configuration) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try Data(contentsOf: audio)
        do {
            _ = try await TranscriptionPipeline.transcribe(audio: audio, directory: root, duration: 1, configuration: configuration,
                recognizer: StubRecognizer(invalid: true), provider: nil, onReviewed: { _ in XCTFail("Invalid timestamps published") })
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(try Data(contentsOf: audio), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("local-asr-original.json").path))
        }
    }

    @MainActor func testNoProviderKeepsRawCheckpointPrivateAndRetryReusesASR() async throws {
        let (root, audio, configuration) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = StubRecognizer()
        var published: [TranscriptSegment] = []
        for _ in 0..<2 {
            do {
                _ = try await TranscriptionPipeline.transcribe(audio: audio, directory: root, duration: 1, configuration: configuration,
                    recognizer: backend, provider: nil, onReviewed: { published = $0 })
                XCTFail("Correction must finish before publication")
            } catch { XCTAssertTrue(published.isEmpty) }
        }
        _ = try await TranscriptionPipeline.transcribe(audio: audio, directory: root, duration: 1, configuration: configuration,
            recognizer: backend, provider: StubTextProvider(), onReviewed: { published = $0 })
        XCTAssertEqual(published.first?.timingQuality, "apple-speech")
        XCTAssertEqual(Transcript.activeID(at: 0.5, in: published), 0)
        let calls = await backend.calls; XCTAssertEqual(calls, 1)
    }

    @MainActor func testAnalysisFailurePreservesLocalTranscript() async throws {
        let (root, audio, configuration) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = StubTextProvider(); provider.invalidAnalysis = true
        let result = try await TranscriptionPipeline.transcribe(audio: audio, directory: root, duration: 1,
            configuration: configuration, recognizer: StubRecognizer(), provider: provider)
        guard case .transcribed(let saved, let lecture, let warning, _) = result else { return XCTFail("Expected saved transcript") }
        XCTAssertEqual(saved.first?.originalText, "원문 그대로 보관합니다.")
        XCTAssertEqual(saved.last?.end, 1)
        XCTAssertNil(lecture); XCTAssertNotNil(warning)
    }
}
