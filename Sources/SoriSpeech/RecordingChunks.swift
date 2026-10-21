import Foundation
import AVFoundation
import CryptoKit
import Darwin
import SoriCore

/// File coordinates, not elapsed wall-clock time. End frames are exclusive.
struct RecordingChunk: Codable, Equatable, Sendable {
    let index: Int
    let startFrame: Int64
    let endFrame: Int64
    let quietBoundary: Bool
}

struct RecordingChunkManifest: Codable, Equatable, Sendable {
    let strategy: String
    let audioSHA256: String
    let language: String
    let sampleRate: Int
    let totalFrames: Int64
    let chunks: [RecordingChunk]

    var cacheKey: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try! encoder.encode(self)).map { String(format: "%02x", $0) }.joined()
    }
}

enum RecordingChunks {
    static let strategy = "file-300s-quiet-v1"
    static let sampleRate = 16_000
    static let maximumFrames: Int64 = 300 * 16_000
    static let searchFrames: Int64 = 10 * 16_000

    /// Never exceeds five minutes. Seek a >=260 ms pause in the last ten seconds;
    /// otherwise split exactly at the limit. No text-based deduplication or gaps.
    static func plan(totalFrames: Int64, quietCut: (Int64, Int64) throws -> Int64?) throws -> [RecordingChunk] {
        guard totalFrames > 0, totalFrames <= 4 * 3600 * Int64(sampleRate) else { throw DictationError.invalidAudio }
        var chunks: [RecordingChunk] = []
        var start: Int64 = 0
        while start < totalFrames {
            try Task.checkCancellation()
            let target = min(start + maximumFrames, totalFrames)
            var end = target
            var quiet = false
            if target < totalFrames, let cut = try quietCut(target - searchFrames, target) {
                guard cut >= target - searchFrames, cut <= target else { throw DictationError.invalidAudio }
                end = cut; quiet = true
            }
            chunks.append(RecordingChunk(index: chunks.count, startFrame: start, endFrame: end, quietBoundary: quiet))
            start = end
        }
        return chunks
    }

    static func quietCut(samples: [Float], offset: Int64) -> Int64? {
        let window = 320 // 20 ms at 16 kHz
        let count = samples.count / window
        var firstQuiet: Int?
        var candidate: Int64?
        for frame in 0...count {
            var energy = 0.0
            if frame < count {
                for index in frame * window..<(frame + 1) * window {
                    let sample = Double(samples[index]); energy += sample * sample
                }
            }
            let quiet = frame < count && energy / Double(window) < pow(10, -38.0 / 10)
            if quiet {
                if firstQuiet == nil { firstQuiet = frame }
            } else if let first = firstQuiet {
                if frame - first >= 13 { candidate = offset + Int64((first + frame) * window / 2) }
                firstQuiet = nil
            }
        }
        return candidate
    }

    static func prepare(audio: URL, workspace: URL, ffmpeg: URL, language: String, reuseDirectory: URL? = nil) async throws -> (URL, RecordingChunkManifest, [Int: String]) {
        guard ["ko", "en", "ja", "auto"].contains(language) else { throw DictationError.invalidAudio }
        let hash = try await hashFile(audio)
        let pcm = workspace.appendingPathComponent("normalized.wav")
        try await ProcessRunner().run(executable: ffmpeg,
            arguments: ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", audio.path,
                        "-map", "0:a:0", "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", pcm.path],
            directory: workspace, log: workspace.appendingPathComponent("normalize.log"), timeout: 1800)
        // The caller must supply a closed recording, never a file still being written.
        guard try await hashFile(audio) == hash else { throw SoriError.message("녹음 파일이 변경되었습니다. 녹음을 마친 뒤 다시 시도해 주세요.") }
        let file = try AVAudioFile(forReading: pcm)
        guard file.processingFormat.sampleRate == Double(sampleRate), file.processingFormat.channelCount == 1 else {
            throw DictationError.invalidAudio
        }
        var chunks = try plan(totalFrames: file.length) { start, end in
            file.framePosition = start
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(end - start)) else {
                throw DictationError.invalidAudio
            }
            try file.read(into: buffer)
            guard Int64(buffer.frameLength) == end - start, let samples = buffer.floatChannelData?[0] else { throw DictationError.invalidAudio }
            return quietCut(samples: Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength))), offset: start)
        }
        var saved: [Int: String] = [:]
        if let reuseDirectory, let live = try? LiveChunkStore.read(reuseDirectory, language: language), !live.closed {
            // An interrupted session can be sealed from its now-closed PCM copy.
            // Reuse still requires byte-for-byte checks against this completed audio.
            _ = try? await LiveChunkStore.scan(audio: pcm, directory: reuseDirectory, language: language, closed: true)
        }
        if let reuseDirectory, let reuse = try? LiveChunkStore.reusable(pcm: pcm, directory: reuseDirectory, language: language) {
            chunks = reuse.chunks; saved = reuse.text
        }
        return (pcm, RecordingChunkManifest(strategy: strategy, audioSHA256: hash, language: language,
            sampleRate: sampleRate, totalFrames: file.length, chunks: chunks), saved)
    }

    /// Copies PCM samples exactly; AAC encoding happens only after this slice is closed.
    static func extract(_ chunk: RecordingChunk, from audio: URL, to output: URL) throws {
        let input = try AVAudioFile(forReading: audio, commonFormat: .pcmFormatInt16, interleaved: true)
        input.framePosition = chunk.startFrame
        guard chunk.startFrame >= 0, chunk.endFrame <= input.length, chunk.endFrame > chunk.startFrame,
              let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 16_000) else { throw DictationError.invalidAudio }
        let file = try AVAudioFile(forWriting: output, settings: input.fileFormat.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        var remaining = chunk.endFrame - chunk.startFrame
        while remaining > 0 {
            try Task.checkCancellation()
            try input.read(into: buffer, frameCount: AVAudioFrameCount(min(remaining, 16_000)))
            guard buffer.frameLength > 0 else { throw DictationError.invalidAudio }
            try file.write(from: buffer)
            remaining -= Int64(buffer.frameLength)
        }
    }

    static func hashFile(_ url: URL) async throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var digest = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation(); digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Durable results live beside the output, not in the disposable execution workspace.
/// A response is an ASR result, never proof that every word was recognized or aligned.
@MainActor
enum ChunkTranscription {
    struct Text: Codable {
        let text: String
        var skippedDigitalSilence = false
        var origin: String? = nil
    }
    struct Result: Codable {
        let cacheKey: String
        let chunk: RecordingChunk
        let response: Text
        let elapsedSeconds: Double
    }
    struct Document: Codable {
        var schemaVersion = 2
        var source = "codex-dictation"
        var status = "transcribed"
        var contentCoverageVerified = false
        var sentenceTimingVerified = false
        let manifest: RecordingChunkManifest
        let text: String
        let chunks: [Result]
    }

    static func run(manifest: RecordingChunkManifest, output: URL,
                    transcribe: (RecordingChunk) async throws -> Text) async throws -> String {
        let directory = output.deletingPathExtension().appendingPathExtension("chunks").appendingPathComponent(manifest.cacheKey)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(directory.appendingPathComponent("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw SoriError.message("전사 작업을 저장할 수 없습니다.") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw SoriError.message("같은 녹음의 전사가 이미 진행 중입니다.") }
        defer { flock(descriptor, LOCK_UN) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        var results: [Result] = []
        for chunk in manifest.chunks {
            try Task.checkCancellation()
            let url = directory.appendingPathComponent(String(format: "%03d.json", chunk.index))
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4 * 1024 * 1024,
               let data = try? Data(contentsOf: url), let cached = try? JSONDecoder().decode(Result.self, from: data),
               cached.cacheKey == manifest.cacheKey, cached.chunk == chunk, valid(cached.response) {
                results.append(cached)
                continue
            }
            let start = ProcessInfo.processInfo.systemUptime
            let response = try await transcribe(chunk)
            try Task.checkCancellation()
            guard valid(response) else { throw DictationError.empty }
            let result = Result(cacheKey: manifest.cacheKey, chunk: chunk, response: response,
                                elapsedSeconds: ProcessInfo.processInfo.systemUptime - start)
            try encoder.encode(result).write(to: url, options: .atomic)
            results.append(result)
        }
        try Task.checkCancellation()
        let text = results.map(\.response.text).filter { !$0.isEmpty }.joined(separator: "\n")
        guard !text.isEmpty else { throw DictationError.empty }
        guard text.utf8.count <= 4 * 1024 * 1024 else { throw DictationError.invalidResponse }
        try encoder.encode(Document(manifest: manifest, text: text, chunks: results)).write(to: output, options: .atomic)
        return text
    }

    private static func valid(_ response: Text) -> Bool {
        if response.skippedDigitalSilence { return response.text.isEmpty }
        return !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && response.text.utf8.count <= 4 * 1024 * 1024
    }
}
