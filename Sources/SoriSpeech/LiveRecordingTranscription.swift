import Foundation
import AVFoundation
import CryptoKit
import SoriCore
import DoongdoongCodex

/// Reads only the immutable PCM prefix of a WAV still owned by AVAudioRecorder.
/// The recorder's unfinished RIFF/data lengths are not used as a clock.
enum RecordingPCM {
    struct Header { let offset: UInt64; let frames: Int64 }
    static func header(_ url: URL, closed: Bool) throws -> Header {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let size = try file.seekToEnd(); try file.seek(toOffset: 0)
        guard let data = try file.read(upToCount: Int(min(size, 1_048_576))), data.count >= 12,
              String(decoding: data[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: data[8..<12], as: UTF8.self) == "WAVE" else { throw DictationError.invalidAudio }
        func number(_ at: Int, _ bytes: Int) -> UInt64 {
            (0..<bytes).reduce(0) { $0 | UInt64(data[at + $1]) << ($1 * 8) }
        }
        var position = 12, validFormat = false
        while position + 8 <= data.count {
            let name = String(decoding: data[position..<position + 4], as: UTF8.self)
            let length = Int(number(position + 4, 4)), payload = position + 8
            if name == "fmt " {
                guard length >= 16, payload + 16 <= data.count else { throw DictationError.invalidAudio }
                validFormat = number(payload, 2) == 1 && number(payload + 2, 2) == 1
                    && number(payload + 4, 4) == 16000 && number(payload + 12, 2) == 2 && number(payload + 14, 2) == 16
            }
            if name == "data" {
                guard validFormat, size >= payload else { throw DictationError.invalidAudio }
                var frames = Int64((size - UInt64(payload)) / 2)
                if closed { frames = min(frames, try AVAudioFile(forReading: url).length) }
                guard frames <= 4 * 3600 * 16000 else { throw DictationError.invalidAudio }
                return Header(offset: UInt64(payload), frames: frames)
            }
            guard length <= 1_048_576, payload + length <= data.count else { throw DictationError.invalidAudio }
            position = payload + length + length % 2
        }
        throw DictationError.invalidAudio
    }

    static func samples(_ url: URL, header: Header, start: Int64, end: Int64) throws -> Data {
        guard start >= 0, end > start, end <= header.frames, end - start <= RecordingChunks.maximumFrames else {
            throw DictationError.invalidAudio
        }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        try file.seek(toOffset: header.offset + UInt64(start) * 2)
        let count = Int(end - start) * 2
        guard let data = try file.read(upToCount: count), data.count == count else { throw DictationError.invalidAudio }
        return data
    }

    static func wave(_ pcm: Data) -> Data { waveHeader(bytes: pcm.count) + pcm }
    static func waveHeader(bytes: Int) -> Data {
        var data = Data("RIFF".utf8)
        func u32(_ v: UInt32) { var v = v.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var v = v.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        u32(UInt32(36 + bytes)); data.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(16000); u32(32000); u16(2); u16(16); data.append(Data("data".utf8)); u32(UInt32(bytes))
        return data
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

enum LiveChunkStore {
    struct Entry: Codable { let chunk: RecordingChunk; let pcmSHA256: String }
    struct Manifest: Codable {
        let version: Int
        let strategy: String
        let language: String
        var closed: Bool
        var totalFrames: Int64?
        var entries: [Entry]
    }
    static func folder(_ directory: URL) -> URL { directory.appendingPathComponent("live-asr") }
    static func audioURL(_ directory: URL, index: Int) -> URL { folder(directory).appendingPathComponent("\(index).wav") }
    static func outputURL(_ directory: URL, index: Int) -> URL { folder(directory).appendingPathComponent("\(index).json") }

    static func read(_ directory: URL, language: String?) throws -> Manifest? {
        let url = folder(directory).appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576 else { throw DictationError.invalidResponse }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        guard manifest.version == 1, manifest.strategy == RecordingChunks.strategy, ["ko", "en", "ja", "auto"].contains(manifest.language),
              language == nil || manifest.language == language else {
            throw DictationError.invalidResponse
        }
        var previous: Int64 = 0
        for (index, entry) in manifest.entries.enumerated() {
            guard entry.chunk.index == index, entry.chunk.startFrame == previous, entry.chunk.endFrame > previous,
                  entry.chunk.endFrame - previous <= RecordingChunks.maximumFrames else { throw DictationError.invalidResponse }
            previous = entry.chunk.endFrame
        }
        if manifest.closed, manifest.totalFrames != previous { throw DictationError.invalidResponse }
        return manifest
    }

    /// Pure file work executes off the main actor. Save the closed audio before its manifest entry.
    static func scan(audio: URL, directory: URL, language: String, closed: Bool) async throws -> Manifest {
        try Task.checkCancellation()
        let header = try RecordingPCM.header(audio, closed: closed)
        var manifest = try read(directory, language: language) ?? Manifest(version: 1, strategy: RecordingChunks.strategy,
            language: language, closed: false, totalFrames: nil, entries: [])
        if manifest.closed {
            guard manifest.totalFrames == header.frames else { throw DictationError.invalidAudio }
            return manifest
        }
        try FileManager.default.createDirectory(at: folder(directory), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try save(manifest, directory: directory)
        var start = manifest.entries.last?.chunk.endFrame ?? 0
        guard start <= header.frames else { throw DictationError.invalidAudio }
        while header.frames - start >= RecordingChunks.maximumFrames || closed && start < header.frames {
            try Task.checkCancellation()
            let target = min(start + RecordingChunks.maximumFrames, header.frames)
            var end = target, quiet = false
            if target < header.frames || !closed {
                let left = target - RecordingChunks.searchFrames
                let data = try RecordingPCM.samples(audio, header: header, start: left, end: target)
                let samples = data.withUnsafeBytes { raw in
                    raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768 }
                }
                if let cut = RecordingChunks.quietCut(samples: samples, offset: left) { end = cut; quiet = true }
            }
            let pcm = try RecordingPCM.samples(audio, header: header, start: start, end: end)
            let index = manifest.entries.count
            try RecordingPCM.wave(pcm).write(to: audioURL(directory, index: index), options: .atomic)
            manifest.entries.append(.init(chunk: .init(index: index, startFrame: start, endFrame: end, quietBoundary: quiet),
                                          pcmSHA256: RecordingPCM.hash(pcm)))
            try save(manifest, directory: directory)
            start = end
        }
        if closed { manifest.closed = true; manifest.totalFrames = header.frames; try save(manifest, directory: directory) }
        return manifest
    }

    private static func save(_ manifest: Manifest, directory: URL) throws {
        try JSONEncoder().encode(manifest).write(to: folder(directory).appendingPathComponent("manifest.json"), options: .atomic)
    }

    /// Verify every sample range against the finished original before trusting live work.
    static func reusable(pcm: URL, directory: URL, language: String) throws -> (chunks: [RecordingChunk], text: [Int: String])? {
        guard let manifest = try? read(directory, language: language), manifest.closed else { return nil }
        let header = try RecordingPCM.header(pcm, closed: true)
        guard manifest.totalFrames == header.frames else { return nil }
        var texts: [Int: String] = [:]
        for entry in manifest.entries {
            let chunk = entry.chunk
            let samples = try RecordingPCM.samples(pcm, header: header, start: chunk.startFrame, end: chunk.endFrame)
            guard RecordingPCM.hash(samples) == entry.pcmSHA256 else { return nil }
            let url = outputURL(directory, index: chunk.index)
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4 * 1024 * 1024,
                  let data = try? Data(contentsOf: url), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let savedManifest = object["manifest"] as? [String: Any],
                  savedManifest["language"] as? String == language, savedManifest["strategy"] as? String == RecordingChunks.strategy,
                  savedManifest["audioSHA256"] as? String == RecordingPCM.hash(RecordingPCM.wave(samples)),
                  let text = object["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            texts[chunk.index] = text
        }
        return (manifest.entries.map(\.chunk), texts)
    }
}

/// Recording and uploads have independent lifetimes. Upload failures never stop the microphone.
@MainActor
public final class LiveRecordingTranscription {
    private let audio: URL, directory: URL, codex: URL, ffmpeg: URL
    private let language: String
    private let selection: CodexModel
    private var worker: Task<Void, Never>?
    private var stopping = false
    public var onIssue: ((String) -> Void)?

    public init(audio: URL, directory: URL, codex: URL, ffmpeg: URL, language: String, selection: CodexModel) {
        self.audio = audio; self.directory = directory; self.codex = codex; self.ffmpeg = ffmpeg; self.language = language
        self.selection = selection
    }

    public func start() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            var nextAttempt = Date.distantPast
            while !Task.isCancelled && !self.stopping {
                do {
                    let manifest = try await LiveChunkStore.scan(audio: self.audio, directory: self.directory, language: self.language, closed: false)
                    if Date() >= nextAttempt {
                        for entry in manifest.entries {
                            try Task.checkCancellation()
                            let output = LiveChunkStore.outputURL(self.directory, index: entry.chunk.index)
                            if FileManager.default.fileExists(atPath: output.path) { continue }
                            let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("doongdoong-live-\(UUID().uuidString)")
                            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                            defer { try? FileManager.default.removeItem(at: workspace) }
                            _ = try await SolTranscription.transcribe(audio: LiveChunkStore.audioURL(self.directory, index: entry.chunk.index),
                                workspace: workspace, output: output, codex: self.codex, ffmpeg: self.ffmpeg,
                                language: self.language, selection: self.selection)
                        }
                    }
                } catch {
                    if Task.isCancelled || self.stopping { break }
                    // Back off; never spin on login, 429, offline or incomplete WAV headers.
                    nextAttempt = Date().addingTimeInterval(60)
                    if self.audioExistsLongEnough { self.onIssue?("녹음은 계속 저장하고 있습니다. AI 연결이 복구되면 이어서 처리합니다.") }
                }
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
    }

    private var audioExistsLongEnough: Bool {
        (try? audio.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { $0 > 16000 * 2 * 300 } ?? false
    }

    /// Call after the recorder closes its file. Cancellation preserves all completed responses.
    public func finish() async {
        stopping = true; worker?.cancel(); await worker?.value; worker = nil
        do { _ = try await LiveChunkStore.scan(audio: audio, directory: directory, language: language, closed: true) }
        catch { onIssue?("녹음은 보관되어 있습니다. 저장된 원본에서 AI 정리를 다시 시작합니다.") }
    }

    /// Repair only a known interrupted recording into a NEW file. The original
    /// bytes and unfinished header remain available for recovery or inspection.
    public nonisolated static func recoverInterrupted(audio: URL, directory: URL, language: String) async throws -> URL? {
        guard let manifest = try? LiveChunkStore.read(directory, language: nil), !manifest.closed else { return nil }
        let header = try RecordingPCM.header(audio, closed: false)
        guard header.frames > 0 else { return nil }
        if let finalized = try? RecordingPCM.header(audio, closed: true), finalized.frames == header.frames { return nil }
        for entry in manifest.entries {
            let bytes = try RecordingPCM.samples(audio, header: header, start: entry.chunk.startFrame, end: entry.chunk.endFrame)
            guard RecordingPCM.hash(bytes) == entry.pcmSHA256 else { throw DictationError.invalidAudio }
        }
        let fingerprint = try await RecordingChunks.hashFile(audio)
        let output = directory.appendingPathComponent("audio-recovered.wav")
        let receipt = directory.appendingPathComponent("audio-recovery.json")
        if FileManager.default.fileExists(atPath: output.path) {
            guard let data = try? Data(contentsOf: receipt), let saved = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  saved["sourceSHA256"] == fingerprint, saved["recoveredSHA256"] == (try await RecordingChunks.hashFile(output)) else {
                throw SoriError.message("기존 복구 파일을 덮어쓰지 않았습니다. 작업 폴더의 음성을 확인해 주세요.")
            }
            return output
        }
        let temporary = directory.appendingPathComponent(".recover-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw SoriError.message("녹음 복구 파일을 저장할 수 없습니다.")
        }
        let input = try FileHandle(forReadingFrom: audio), writer = try FileHandle(forWritingTo: temporary)
        defer { try? input.close(); try? writer.close() }
        let count = Int(header.frames * 2)
        try writer.write(contentsOf: RecordingPCM.waveHeader(bytes: count))
        try input.seek(toOffset: header.offset)
        var remaining = count
        while remaining > 0 {
            try Task.checkCancellation()
            guard let bytes = try input.read(upToCount: min(remaining, 1_048_576)), !bytes.isEmpty else { throw DictationError.invalidAudio }
            try writer.write(contentsOf: bytes); remaining -= bytes.count
        }
        try writer.synchronize(); try writer.close()
        guard try await RecordingChunks.hashFile(audio) == fingerprint else { throw DictationError.invalidAudio }
        guard try RecordingPCM.header(temporary, closed: true).frames == header.frames else { throw DictationError.invalidAudio }
        let recoveredHash = try await RecordingChunks.hashFile(temporary)
        try JSONSerialization.data(withJSONObject: ["sourceSHA256": fingerprint, "recoveredSHA256": recoveredHash], options: [.sortedKeys])
            .write(to: receipt, options: .atomic)
        try FileManager.default.moveItem(at: temporary, to: output)
        return output
    }
}
