import XCTest
import SoriCore
@testable import SoriSpeech

final class LiveRecordingTests: XCTestCase {
    func testGrowingRecordingUsesSavedSamplesAndFinalTailWithoutInterruptingOrDuplicating() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("audio.wav")
        // Nonzero PCM avoids a quiet boundary, so exact sample counts are observable.
        let pcm = Data(repeating: 63, count: 603 * 16000 * 2)
        let header = RecordingPCM.wave(Data()) // The active recorder has not finalized lengths.
        try (header + pcm.prefix(299 * 16000 * 2)).write(to: audio)
        let empty = try await LiveChunkStore.scan(audio: audio, directory: root, language: "ko", closed: false)
        XCTAssertTrue(empty.entries.isEmpty)
        let writer = try FileHandle(forWritingTo: audio)
        try writer.seekToEnd(); try writer.write(contentsOf: pcm[299 * 16000 * 2..<302 * 16000 * 2]); try writer.close()
        let first = try await LiveChunkStore.scan(audio: audio, directory: root, language: "ko", closed: false)
        XCTAssertEqual(first.entries.count, 1)
        XCTAssertEqual(first.entries[0].chunk.endFrame, 300 * 16000)
        let slice = LiveChunkStore.audioURL(root, index: 0)
        let snapshot = try Data(contentsOf: slice)
        let paused = try await LiveChunkStore.scan(audio: audio, directory: root, language: "ko", closed: false)
        XCTAssertEqual(paused.entries.count, 1)
        XCTAssertEqual(try Data(contentsOf: slice), snapshot)
        // Simulate the recorder closing its WAV. Scanning keeps earlier boundaries.
        try RecordingPCM.wave(pcm).write(to: audio, options: .atomic)
        let final = try await LiveChunkStore.scan(audio: audio, directory: root, language: "ko", closed: true)
        XCTAssertTrue(final.closed)
        XCTAssertEqual(final.totalFrames, 603 * 16000)
        XCTAssertEqual(final.entries.count, 3)
        XCTAssertEqual(final.entries.last!.chunk.endFrame - final.entries.last!.chunk.startFrame, 3 * 16000)
        XCTAssertEqual(try Data(contentsOf: slice), snapshot)
        var joined = Data()
        for entry in final.entries {
            let url = LiveChunkStore.audioURL(root, index: entry.chunk.index)
            let head = try RecordingPCM.header(url, closed: true)
            joined += try RecordingPCM.samples(url, header: head, start: 0, end: head.frames)
        }
        XCTAssertEqual(joined, pcm)
        let again = try await LiveChunkStore.scan(audio: audio, directory: root, language: "ko", closed: true)
        XCTAssertEqual(again.entries.count, 3)
        XCTAssertEqual(try Data(contentsOf: audio), RecordingPCM.wave(pcm))
    }

    func testLiveResultReuseRequiresExactFinishedAudioLanguageAndResponseIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("audio.wav")
        var pcm = Data(repeating: 63, count: 16000 * 2)
        try RecordingPCM.wave(pcm).write(to: audio)
        _ = try await LiveChunkStore.scan(audio: audio, directory: root, language: "ko", closed: true)
        let object: [String: Any] = ["text": "미리 전사한 결과", "manifest": ["language": "ko", "strategy": RecordingChunks.strategy,
            "audioSHA256": RecordingPCM.hash(RecordingPCM.wave(pcm))]]
        try JSONSerialization.data(withJSONObject: object).write(to: LiveChunkStore.outputURL(root, index: 0))
        XCTAssertEqual(try LiveChunkStore.reusable(pcm: audio, directory: root, language: "ko")?.text[0], "미리 전사한 결과")
        XCTAssertNil(try LiveChunkStore.reusable(pcm: audio, directory: root, language: "en"))
        pcm[0] ^= 1; try RecordingPCM.wave(pcm).write(to: audio)
        XCTAssertNil(try LiveChunkStore.reusable(pcm: audio, directory: root, language: "ko"))
    }

    func testIncompleteOrUnsupportedWAVNeverProducesAnUploadableChunk() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("audio.wav")
        for input in [Data(), Data("RIFF".utf8), Data(repeating: 0, count: 50)] {
            try input.write(to: audio)
            do {
                _ = try await LiveChunkStore.scan(audio: audio, directory: root, language: "ko", closed: false)
                XCTFail("Unsupported input")
            } catch { XCTAssertEqual(try Data(contentsOf: audio), input) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: LiveChunkStore.audioURL(root, index: 0).path))
        }
    }

    func testInterruptedHeaderRecoveryWritesANewFileAndPreservesEverySavedSample() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("audio.wav")
        let pcm = Data(repeating: 63, count: 4 * 16000 * 2)
        let interrupted = RecordingPCM.wave(Data()) + pcm
        try interrupted.write(to: audio)
        _ = try await LiveChunkStore.scan(audio: audio, directory: root, language: "ko", closed: false)
        // Changing the transcription language must not prevent recovery of audio bytes.
        let recovered = try await LiveRecordingTranscription.recoverInterrupted(audio: audio, directory: root, language: "en")
        let destination = try XCTUnwrap(recovered)
        XCTAssertNotEqual(destination, audio)
        XCTAssertEqual(try Data(contentsOf: audio), interrupted)
        XCTAssertEqual(try Data(contentsOf: destination), RecordingPCM.wave(pcm))
        let repeated = try await LiveRecordingTranscription.recoverInterrupted(audio: audio, directory: root, language: "ko")
        XCTAssertEqual(repeated, destination)
        // A user-modified recovery must not be silently replaced on retry.
        try Data("user repair".utf8).write(to: destination)
        do {
            _ = try await LiveRecordingTranscription.recoverInterrupted(audio: audio, directory: root, language: "ko")
            XCTFail("Should preserve an existing recovery")
        } catch { XCTAssertEqual(try Data(contentsOf: destination), Data("user repair".utf8)) }
        XCTAssertEqual(try Data(contentsOf: audio), interrupted)
    }
}
