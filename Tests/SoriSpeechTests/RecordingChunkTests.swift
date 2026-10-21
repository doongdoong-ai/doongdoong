import XCTest
import AVFoundation
import SoriCore
@testable import SoriSpeech

final class RecordingChunkTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func manifest(language: String = "ko", hash: String = "original", strategy: String = RecordingChunks.strategy) throws -> RecordingChunkManifest {
        RecordingChunkManifest(strategy: strategy, audioSHA256: hash, language: language,
            sampleRate: 16000, totalFrames: 601 * 16000,
            chunks: try RecordingChunks.plan(totalFrames: 601 * 16000) { _, _ in nil })
    }

    func testFiveMinuteBoundAndExactCoverageIncludingOneSampleTail() throws {
        let durations: [Int64] = [1, 300 * 16000, 300 * 16000 + 1, 70_166_637, 4 * 3600 * 16000]
        for total in durations {
            let chunks = try RecordingChunks.plan(totalFrames: total) { _, _ in nil }
            XCTAssertEqual(chunks.first?.startFrame, 0)
            XCTAssertEqual(chunks.last?.endFrame, total)
            XCTAssertEqual(chunks.reduce(Int64(0)) { $0 + $1.endFrame - $1.startFrame }, total)
            for (index, chunk) in chunks.enumerated() {
                XCTAssertEqual(chunk.index, index)
                XCTAssertGreaterThan(chunk.endFrame, chunk.startFrame)
                XCTAssertLessThanOrEqual(chunk.endFrame - chunk.startFrame, 300 * 16000)
                if index > 0 { XCTAssertEqual(chunk.startFrame, chunks[index - 1].endFrame) }
            }
        }
        XCTAssertThrowsError(try RecordingChunks.plan(totalFrames: 0) { _, _ in nil })
        XCTAssertThrowsError(try RecordingChunks.plan(totalFrames: 301 * 16000) { _, end in end + 1 })
    }

    func testQuietBoundaryRequiresPauseAndKeepsRepeatedSpeechSamples() throws {
        var samples = [Float](repeating: 0.1, count: 16000 * 10)
        for index in 16000 * 8..<16000 * 9 { samples[index] = 0 }
        let offset: Int64 = 290 * 16000
        XCTAssertEqual(RecordingChunks.quietCut(samples: samples, offset: offset), 298 * 16000 + 8000)
        let chunks = try RecordingChunks.plan(totalFrames: 601 * 16000) { start, _ in
            RecordingChunks.quietCut(samples: samples, offset: start)
        }
        XCTAssertTrue(chunks[0].quietBoundary)
        XCTAssertEqual(chunks[0].endFrame, chunks[1].startFrame)
        XCTAssertEqual(chunks.last?.endFrame, 601 * 16000)
        XCTAssertNil(RecordingChunks.quietCut(samples: [Float](repeating: 0.1, count: 16000), offset: 0))
        XCTAssertNil(RecordingChunks.quietCut(samples: [Float](repeating: 0, count: 320 * 12), offset: 0))
    }

    func testExtractionPreservesEveryPCMValue() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("source.wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
        let samples = (0..<32003).map { Int16(($0 * 71) % 60000 - 30000) }
        do {
            let file = try AVAudioFile(forWriting: audio, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
            buffer.frameLength = buffer.frameCapacity
            for (index, value) in samples.enumerated() { buffer.int16ChannelData![0][index] = value }
            try file.write(from: buffer)
        }
        var restored: [Int16] = []
        for (index, bounds) in [(Int64(0), Int64(16001)), (Int64(16001), Int64(32003))].enumerated() {
            let slice = root.appendingPathComponent("\(index).wav")
            try RecordingChunks.extract(RecordingChunk(index: index, startFrame: bounds.0, endFrame: bounds.1, quietBoundary: false), from: audio, to: slice)
            let file = try AVAudioFile(forReading: slice, commonFormat: .pcmFormatInt16, interleaved: true)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            restored += Array(UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength)))
        }
        XCTAssertEqual(restored, samples)
    }

    @MainActor func testFailureRetainsChunksAndRetryDoesNotUploadCompletedChunks() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("asr.json")
        let manifest = try manifest()
        do {
            _ = try await ChunkTranscription.run(manifest: manifest, output: output) { chunk in
                if chunk.index == 1 { throw DictationError.rateLimited }
                return .init(text: "반복 설명.")
            }
            XCTFail("Expected upload failure")
        } catch DictationError.rateLimited { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        var uploaded: [Int] = []
        let text = try await ChunkTranscription.run(manifest: manifest, output: output) { chunk in
            uploaded.append(chunk.index)
            return .init(text: chunk.index == 1 ? "반복 설명." : "마지막 시험 범위.")
        }
        XCTAssertEqual(uploaded, [1, 2])
        XCTAssertEqual(text, "반복 설명.\n반복 설명.\n마지막 시험 범위.")
        let document = try JSONDecoder().decode(ChunkTranscription.Document.self, from: Data(contentsOf: output))
        XCTAssertEqual(document.chunks.count, 3)
        XCTAssertFalse(document.contentCoverageVerified)
        XCTAssertFalse(document.sentenceTimingVerified)
    }

    @MainActor func testCacheChangesWithLanguageSourceOrStrategy() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("asr.json")
        for manifest in [try manifest(), try manifest(language: "en"), try manifest(hash: "changed"), try manifest(strategy: "other")] {
            var requests = 0
            _ = try await ChunkTranscription.run(manifest: manifest, output: output) { _ in requests += 1; return .init(text: "원문") }
            XCTAssertEqual(requests, 3)
        }
        _ = try await ChunkTranscription.run(manifest: manifest(), output: output) { _ in
            XCTFail("Original cache is still reusable"); return .init(text: "wrong")
        }
    }

    @MainActor func testEmptyResponseAndCancellationNeverPublishPartialOutput() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("asr.json")
        let manifest = try manifest()
        do {
            _ = try await ChunkTranscription.run(manifest: manifest, output: output) { _ in .init(text: " ") }
            XCTFail("Empty recognition cannot be marked as silence")
        } catch DictationError.empty { }
        do {
            _ = try await ChunkTranscription.run(manifest: manifest, output: output) { chunk in
                if chunk.index == 1 { throw CancellationError() }
                return .init(text: "첫 부분")
            }
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    @MainActor func testCorruptOrMismatchedChunkIsRetriedAndPreviousDocumentSurvivesFailure() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("asr.json")
        let manifest = try manifest()
        _ = try await ChunkTranscription.run(manifest: manifest, output: output) { chunk in .init(text: "원문 \(chunk.index)") }
        let previous = try Data(contentsOf: output)
        let directory = root.appendingPathComponent("asr.chunks").appendingPathComponent(manifest.cacheKey)
        try Data("broken".utf8).write(to: directory.appendingPathComponent("001.json"))
        // A valid JSON response for the wrong coordinates must also be rejected.
        try Data(contentsOf: directory.appendingPathComponent("000.json")).write(to: directory.appendingPathComponent("002.json"))
        var retried: [Int] = []
        do {
            _ = try await ChunkTranscription.run(manifest: manifest, output: output) { chunk in
                retried.append(chunk.index)
                if chunk.index == 2 { throw DictationError.unavailable }
                return .init(text: "원문 1")
            }
            XCTFail("Expected unavailable server")
        } catch DictationError.unavailable { }
        XCTAssertEqual(retried, [1, 2])
        XCTAssertEqual(try Data(contentsOf: output), previous)
    }
}
