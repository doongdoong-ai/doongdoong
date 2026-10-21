import Foundation
import SoriCore
import DoongdoongTranscription

/// Application adapter. Correction, titles and emphasis stay outside the core.
public enum CloudTranscription {
    public static let engine = ChatGPTSpeechRecognizer.shared

    public static func prepareRecording(directory: URL) throws {
        try TranscriptionSession.prepareRecording(directory: directory)
    }

    public static func transcribe(audio: URL, directory: URL, configuration: TranscriptionConfiguration,
                                  recognizer: any SpeechRecognizer = engine,
                                  onProgress: (@Sendable (TranscriptionProgress) async -> Void)? = nil) async throws -> [TranscriptSegment] {
        let session = TranscriptionSession(audio: audio, directory: directory, configuration: configuration, recognizer: recognizer)
        let speech = try await session.processAvailable(final: true, onProgress: onProgress)
        let segments = speech.enumerated().map { index, value in
            var segment = TranscriptSegment(id: index, start: value.start, end: value.end, text: value.text)
            segment.timingQuality = value.timingQuality
            return segment
        }
        let values = try JSONSerialization.jsonObject(with: JSONEncoder().encode(segments))
        try JSONSerialization.data(withJSONObject: ["method": "chatgpt-file-mms", "text": segments.map(\.text).joined(separator: "\n"),
                                                     "segments": values], options: [.sortedKeys])
            .write(to: directory.appendingPathComponent("asr-original.json"), options: .atomic)
        return segments
    }

    public static func recoverInterrupted(audio: URL, directory: URL, language: String) async throws -> URL? {
        try await TranscriptionSession.recoverInterrupted(audio: audio, directory: directory)
    }
}

@MainActor
public final class RecordingTranscription {
    private let session: TranscriptionSession
    private var worker: Task<Void, Never>?
    private var stopping = false
    public var onIssue: ((String) -> Void)?

    public init(audio: URL, directory: URL, configuration: TranscriptionConfiguration, recognizer: any SpeechRecognizer = CloudTranscription.engine) {
        session = TranscriptionSession(audio: audio, directory: directory, configuration: configuration, recognizer: recognizer)
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

    /// Normal stop drains the current file and preserves its checkpoint.
    /// The app's final pipeline reuses checkpoints and processes only the tail.
    public func finish(cancel: Bool = false) async {
        stopping = true
        if cancel { worker?.cancel() }
        await worker?.value; worker = nil
    }
}
