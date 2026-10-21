import Foundation
import XCTest
import SoriCore
import DoongdoongTranscription
@testable import SoriApp

private actor StubRecognizer: SpeechRecognizer {
    var calls = 0
    let invalid: Bool
    init(invalid: Bool = false) { self.invalid = invalid }
    func transcribe(wave: Data, configuration: WhisperConfiguration) async throws -> [SpeechSegment] {
        calls += 1
        return [.init(start: 0, end: invalid ? 100 : 1, text: "원문 그대로 보관합니다.")]
    }
}

final class TranscriptionPipelineTests: XCTestCase {
    @MainActor private func fixture() throws -> (URL, URL, PipelineSettings) {
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
        let model = root.appendingPathComponent("model.bin"); try Data([1]).write(to: model)
        let config = WhisperConfiguration(executable: URL(fileURLWithPath: "/usr/bin/true"), model: model, vadModel: model)
        return (root, audio, PipelineSettings(codex: "/usr/bin/false", ffmpeg: "/usr/bin/false", language: "ko", transcription: config))
    }

    @MainActor func testInvalidTimestampsAreNotPublishedAndOriginalAudioIsUntouched() async throws {
        let (root, audio, settings) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try Data(contentsOf: audio)
        do {
            _ = try await TranscriptionPipeline.transcribe(audio: audio, directory: root, duration: 1, settings: settings,
                recognizer: StubRecognizer(invalid: true), onTranscribed: { _ in XCTFail("Invalid timestamps published") })
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(try Data(contentsOf: audio), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("local-asr-original.json").path))
        }
    }

    @MainActor func testNoCodexStillProducesTranscriptAndClickableTimestampsWithoutRepeatingASR() async throws {
        let (root, audio, settings) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = StubRecognizer()
        var published: [TranscriptSegment] = []
        for _ in 0..<2 {
            let result = try await TranscriptionPipeline.transcribe(audio: audio, directory: root, duration: 1, settings: settings,
                recognizer: backend, onTranscribed: { published = $0 })
            guard case .transcribed(let saved, let lecture, let warning, _) = result else { return XCTFail("Expected transcript") }
            XCTAssertEqual(saved, published)
            XCTAssertEqual(saved.first?.text, "원문 그대로 보관합니다.")
            XCTAssertEqual(saved.first?.timingQuality, "whisper")
            XCTAssertEqual(Transcript.activeID(at: 0.5, in: saved), 0)
            XCTAssertNil(lecture); XCTAssertNotNil(warning)
        }
        let calls = await backend.calls; XCTAssertEqual(calls, 1)
    }

    @MainActor func testAnalysisFailurePreservesLocalTranscript() async throws {
        let (root, audio, base) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = PipelineSettings(codex: "/usr/bin/false", ffmpeg: base.ffmpeg, language: base.language,
                                        aiModel: .sol, transcription: base.transcription)
        let result = try await TranscriptionPipeline.transcribe(audio: audio, directory: root, duration: 1,
            settings: settings, recognizer: StubRecognizer())
        guard case .transcribed(let saved, let lecture, let warning, _) = result else { return XCTFail("Expected saved transcript") }
        XCTAssertEqual(saved.first?.originalText, "원문 그대로 보관합니다.")
        XCTAssertEqual(saved.last?.end, 1)
        XCTAssertNil(lecture); XCTAssertNotNil(warning)
    }
}
