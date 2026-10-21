import Foundation
import SoriCore
import AVFoundation

public enum TranscriptAlignment {
    public struct Report {
        public let segments: [TranscriptSegment]
        public let reviewRanges: [AudioReviewRange]
    }
    public static var helper: URL {
        if let base = Bundle.main.resourceURL,
           let bundle = Bundle(url: base.appendingPathComponent("Sori_SoriSpeech.bundle")),
           let resources = bundle.resourceURL {
            return resources.appendingPathComponent("align_transcript.py")
        }
        return Bundle.module.resourceURL!.appendingPathComponent("align_transcript.py")
    }

    public static func align(audio: URL, transcript: URL, text: String, duration: Double,
                             python: URL, modelDirectory: URL, workspace: URL,
                             language: String, output: URL, regions: Bool = false, cacheDirectory: URL? = nil) async throws -> Report {
        let intermediate = workspace.appendingPathComponent("alignment.json")
        try await ProcessRunner().run(executable: python,
            arguments: [helper.path, "--audio", audio.path, "--transcript", transcript.path,
                        "--output", intermediate.path, "--model-directory", modelDirectory.path, "--language", language,
                        "--cache-directory", (cacheDirectory ?? output.deletingLastPathComponent().appendingPathComponent("alignment-cache")).path] + (regions ? ["--regions"] : []),
            directory: workspace, log: workspace.appendingPathComponent("alignment.log"),
            timeout: min(86_400, max(300, duration * 6)))
        let data = try Data(contentsOf: intermediate)
        let report = try decodeReport(data, text: text, duration: duration)
        try data.write(to: output, options: .atomic)
        return report
    }

    public static func decode(_ data: Data, text: String, duration: Double) throws -> [TranscriptSegment] {
        try decodeReport(data, text: text, duration: duration).segments
    }

    public static func decodeReport(_ data: Data, text: String, duration: Double) throws -> Report {
        struct Result: Decodable {
            var schemaVersion: Int
            var method: String
            var duration: Double
            var text: String
            var segments: [TranscriptSegment]
            var reviewRanges: [AudioReviewRange]?
        }
        guard data.count <= 16 * 1024 * 1024, duration.isFinite, duration > 0 else {
            throw SoriError.message("음성과 전사문을 정렬할 수 없습니다.")
        }
        let result = try JSONDecoder().decode(Result.self, from: data)
        let compact: (String) -> String = { String($0.filter { !$0.isWhitespace }) }
        guard [1, 2].contains(result.schemaVersion), result.method == "mms-ctc-forced-alignment",
              result.duration.isFinite, abs(result.duration - duration) < 0.1,
              result.text == text, !result.segments.isEmpty,
              compact(result.segments.map(\.text).joined()) == compact(text) else {
            throw SoriError.message("시간 정렬 결과에 전사문 누락 또는 변경이 있습니다.")
        }
        var end = 0.0
        for (index, segment) in result.segments.enumerated() {
            guard segment.id == index, segment.start.isFinite, segment.end.isFinite,
                  segment.start >= end, segment.end > segment.start, segment.end <= duration,
                  !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  segment.originalText == segment.text,
                  segment.timingQuality == nil || ["aligned", "approximate"].contains(segment.timingQuality!),
                  result.schemaVersion == 1 || segment.timingQuality != nil else {
                throw SoriError.message("문장별 재생 위치를 정확하게 확인하지 못했습니다.")
            }
            end = segment.end
        }
        let gaps = result.reviewRanges ?? []
        guard gaps.count <= 20_000, gaps.allSatisfy({
            $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && $0.end <= duration
                && $0.reason == "unmatched_audio"
        }) else { throw SoriError.message("확인이 필요한 음성의 위치를 읽지 못했습니다.") }
        return Report(segments: result.segments, reviewRanges: gaps)
    }

    /// Reject digital silence before uploading; this is not a speech recognizer.
    public static func hasSignal(audio: URL) async throws -> Bool {
        let file = try AVAudioFile(forReading: audio)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else {
            throw SoriError.message("녹음 파일을 읽지 못했습니다.")
        }
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer)
            guard let channels = buffer.floatChannelData else { throw DictationError.invalidAudio }
            for channel in 0..<Int(buffer.format.channelCount) {
                var energy = 0.0
                for index in 0..<Int(buffer.frameLength) {
                    let sample = Double(channels[channel][index])
                    guard sample.isFinite else { throw DictationError.invalidAudio }
                    energy += sample * sample
                }
                if buffer.frameLength > 0 && energy / Double(buffer.frameLength) > 0.00000001 { return true }
            }
        }
        return false
    }
}
