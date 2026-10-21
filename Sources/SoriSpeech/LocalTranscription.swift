import Foundation
import SoriCore
import DoongdoongTranscription

/// Application adapter. Correction, titles and emphasis stay outside the core.
public enum LocalTranscription {
    public static let engine = WhisperEngine()

    public static func prepareRecording(directory: URL) throws {
        try TranscriptionSession.prepareRecording(directory: directory)
    }

    public static func transcribe(audio: URL, directory: URL, configuration: WhisperConfiguration,
                                  recognizer: any SpeechRecognizer = engine,
                                  onProgress: (@Sendable (TranscriptionProgress) async -> Void)? = nil) async throws -> [TranscriptSegment] {
        let session = TranscriptionSession(audio: audio, directory: directory, configuration: configuration, recognizer: recognizer)
        let speech = try await session.processAvailable(final: true, onProgress: onProgress)
        let segments = speech.enumerated().map { index, value in
            var segment = TranscriptSegment(id: index, start: value.start, end: value.end, text: value.text)
            segment.timingQuality = "whisper"
            return segment
        }
        let values = try JSONSerialization.jsonObject(with: JSONEncoder().encode(segments))
        try JSONSerialization.data(withJSONObject: ["method": "local-whisper", "text": segments.map(\.text).joined(separator: "\n"),
                                                     "segments": values], options: [.sortedKeys])
            .write(to: directory.appendingPathComponent("local-asr-original.json"), options: .atomic)
        return segments
    }

    public static func recoverInterrupted(audio: URL, directory: URL, language: String) async throws -> URL? {
        if let recovered = try await TranscriptionSession.recoverInterrupted(audio: audio, directory: directory) { return recovered }
        // Keep recovery for recordings interrupted in the previous app version.
        return try await LiveRecordingTranscription.recoverInterrupted(audio: audio, directory: directory, language: language)
    }
}

@MainActor
public final class LocalRecordingTranscription {
    private let session: TranscriptionSession
    private var worker: Task<Void, Never>?
    private var stopping = false
    public var onIssue: ((String) -> Void)?

    public init(audio: URL, directory: URL, configuration: WhisperConfiguration) {
        session = TranscriptionSession(audio: audio, directory: directory, configuration: configuration, recognizer: LocalTranscription.engine)
    }

    public func start() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            var nextAttempt = Date.distantPast
            while !Task.isCancelled && !self.stopping {
                if Date() >= nextAttempt {
                    do { try await self.session.processAvailable(final: false) }
                    catch {
                        if Task.isCancelled { break }
                        nextAttempt = Date().addingTimeInterval(30)
                        self.onIssue?("녹음은 계속 저장됩니다. 음성 인식을 잠시 후 다시 시도합니다.")
                    }
                }
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
    }

    /// Normal stop drains an in-flight chunk, retaining the resident engine.
    /// The app's final pipeline reuses checkpoints and processes only the tail.
    public func finish(cancel: Bool = false) async {
        stopping = true
        if cancel { worker?.cancel() }
        await worker?.value; worker = nil
    }
}
