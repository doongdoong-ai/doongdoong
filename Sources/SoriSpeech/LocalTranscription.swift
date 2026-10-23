import Foundation
import SoriCore
import DoongdoongTranscription

/// Application adapter. Correction, titles and emphasis stay outside the core.
public enum LocalTranscription {
    public static let engine = AppleSpeechEngine()

    public static func prepareRecording(directory: URL) throws {
        try TranscriptionSession.prepareRecording(directory: directory)
    }

    public static func transcribe(audio: URL, directory: URL, configuration: SpeechConfiguration,
                                  recognizer: any SpeechRecognizer = engine,
                                  onProgress: (@Sendable (TranscriptionProgress) async -> Void)? = nil) async throws -> [TranscriptSegment] {
        let session = TranscriptionSession(audio: audio, directory: directory, configuration: configuration, recognizer: recognizer)
        let speech = try await session.processAvailable(final: true, onProgress: onProgress)
        let segments = speech.enumerated().map { index, value in
            var segment = TranscriptSegment(id: index, start: value.start, end: value.end, text: value.text)
            segment.timingQuality = "apple-speech"
            return segment
        }
        let values = try JSONSerialization.jsonObject(with: JSONEncoder().encode(segments))
        try JSONSerialization.data(withJSONObject: ["method": "apple-speech", "text": segments.map(\.text).joined(separator: "\n"),
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
    // Scheduling is separate from the core's small, resumable decode chunks.
    static let batchFrames: Int64 = 25 * 60 * 16_000
    private let audio: URL
    private let session: TranscriptionSession
    private var worker: Task<Void, Never>?
    private var stopping = false
    private var processing = false
    private var nextBatchFrame = batchFrames
    public var onIssue: ((String) -> Void)?

    public init(audio: URL, directory: URL, configuration: SpeechConfiguration,
                recognizer: any SpeechRecognizer = LocalTranscription.engine) {
        self.audio = audio
        session = TranscriptionSession(audio: audio, directory: directory, configuration: configuration, recognizer: recognizer)
    }

    public func start() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            var nextAttempt = ContinuousClock.now
            while !Task.isCancelled && !self.stopping {
                if ContinuousClock.now >= nextAttempt {
                    do { try await self.processScheduledBatch() }
                    catch {
                        if Task.isCancelled { break }
                        nextAttempt = ContinuousClock.now.advanced(by: .seconds(30))
                        self.onIssue?("녹음은 계속 저장됩니다. 음성 인식을 잠시 후 다시 시도합니다.")
                    }
                }
                if self.stopping { break }
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
    }

    /// Gate on saved PCM, not wall time: pauses do not count toward 25 minutes.
    /// On resume a new session may catch up immediately; core checkpoints avoid
    /// decoding completed chunks again. Advance only after a successful batch.
    func processScheduledBatch() async throws {
        guard !stopping, !processing else { return }
        try Task.checkCancellation()
        let frames = try RecordingPCM.header(audio, closed: false).frames
        guard frames >= nextBatchFrame else { return }
        processing = true; defer { processing = false }
        try await session.processAvailable(final: false)
        nextBatchFrame = (frames / Self.batchFrames + 1) * Self.batchFrames
    }

    /// Stop idle polling immediately; normal stop drains an in-flight batch.
    /// The final pipeline reuses checkpoints and processes the tail without
    /// waiting for another 25-minute boundary. Sleep cancels inference as well.
    public func finish(cancel: Bool = false) async {
        stopping = true
        if cancel || !processing { worker?.cancel() }
        await worker?.value; worker = nil
    }
}
