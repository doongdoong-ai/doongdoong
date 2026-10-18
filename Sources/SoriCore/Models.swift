import Foundation

public struct Project: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id; self.name = name; self.createdAt = createdAt
    }
}

public enum RecordingStatus: String, Codable, Sendable {
    case recording, queued, transcribing, polishing, ready, noSpeech, failed
    public var label: String {
        switch self {
        case .recording: "녹음 중"
        case .queued: "AI 정리 대기"
        case .transcribing, .polishing: "AI 정리 중"
        case .ready: "정리 완료"
        case .noSpeech: "감지된 음성 없음"
        case .failed: "다시 시도 필요"
        }
    }
    public var isProcessing: Bool { self == .transcribing || self == .polishing }
}

public struct TranscriptSegment: Codable, Identifiable, Equatable, Sendable {
    public var id: Int
    public var start: Double
    public var end: Double
    public var text: String
    public var originalText: String
    public init(id: Int, start: Double, end: Double, text: String, originalText: String? = nil) {
        self.id = id; self.start = start; self.end = end; self.text = text
        self.originalText = originalText ?? text
    }
}

public struct Bookmark: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var time: Double
    public var label: String
    public init(time: Double, label: String) { id = UUID(); self.time = time; self.label = label }
}

public struct Recording: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var projectID: UUID
    public var title: String
    public var createdAt: Date
    public var duration: Double
    public var status: RecordingStatus
    public var segments: [TranscriptSegment]
    public var bookmarks: [Bookmark]
    public var notes: String
    public var isFavorite: Bool
    public var waveform: [Float]
    public var message: String?
    public var isDemo: Bool
    // Optional fields keep recordings from earlier versions decodable.
    public var generatedTitle: String?
    public var titleEditedByUser: Bool?
    public var lectureHighlights: [LectureHighlight]?

    public init(id: UUID = UUID(), projectID: UUID, title: String, createdAt: Date = Date()) {
        self.id = id; self.projectID = projectID; self.title = title; self.createdAt = createdAt
        duration = 0; status = .queued; segments = []; bookmarks = []; notes = ""
        isFavorite = false; waveform = []; isDemo = false
    }
    public var fullText: String { segments.map(\.text).joined(separator: "\n") }
}

public enum SoriError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case let .message(value) = self { return value }; return nil }
}

public enum TimeText {
    // A corrupt duration must never trap during Double → Int conversion in the UI.
    private static func bounded(_ seconds: Double) -> Double {
        seconds.isFinite ? min(max(0, seconds), Double(Int32.max)) : 0
    }
    public static func clock(_ seconds: Double) -> String {
        let value = Int(bounded(seconds))
        if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) }
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
    public static func srt(_ seconds: Double) -> String {
        let ms = Int((bounded(seconds) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }
}

public enum Transcript {
    /// A silence gap has no active lyric; end boundaries are exclusive.
    public static func activeID(at time: Double, in segments: [TranscriptSegment]) -> Int? {
        guard time.isFinite else { return nil }
        var lower = 0, upper = segments.count
        while lower < upper {
            let mid = (lower + upper) / 2
            if segments[mid].start <= time { lower = mid + 1 } else { upper = mid }
        }
        guard lower > 0 else { return nil }
        let segment = segments[lower - 1]
        return time < segment.end ? segment.id : nil
    }

    public static func parseWhisper(_ data: Data, duration: Double) throws -> [TranscriptSegment] {
        guard duration.isFinite, duration > 0 else { throw SoriError.message("오디오 길이를 확인할 수 없습니다.") }
        struct Output: Decodable {
            struct Segment: Decodable {
                struct Offsets: Decodable { let from: Double; let to: Double }
                let offsets: Offsets
                let text: String
            }
            let transcription: [Segment]
        }
        let decoded = try JSONDecoder().decode(Output.self, from: data)
        var result: [TranscriptSegment] = []
        for item in decoded.transcription {
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !text.hasPrefix("[_"), item.offsets.from.isFinite, item.offsets.to.isFinite else { continue }
            let start = max(result.last?.end ?? 0, max(0, item.offsets.from / 1000))
            let end = min(duration, item.offsets.to / 1000)
            guard end > start else { continue }
            result.append(.init(id: result.count, start: start, end: end, text: text))
        }
        return result
    }

    public static func applyCorrections(_ data: Data, to segments: [TranscriptSegment]) throws -> [TranscriptSegment] {
        struct Output: Decodable {
            struct Correction: Decodable { let id: Int; let text: String }
            let segments: [Correction]
        }
        let output = try JSONDecoder().decode(Output.self, from: data)
        guard output.segments.count == segments.count,
              Set(segments.map(\.id)).count == segments.count,
              Set(output.segments.map(\.id)).count == output.segments.count,
              Set(output.segments.map(\.id)) == Set(segments.map(\.id)),
              output.segments.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw SoriError.message("Codex 응답의 문장 수 또는 식별자가 일치하지 않습니다. 원본 전사문을 유지했습니다.")
        }
        let corrections = Dictionary(uniqueKeysWithValues: output.segments.map { ($0.id, $0.text) })
        return segments.map { segment in
            var copy = segment
            copy.text = corrections[segment.id]!.trimmingCharacters(in: .whitespacesAndNewlines)
            return copy
        }
    }

    public static func srt(_ segments: [TranscriptSegment]) -> String {
        segments.enumerated().map { index, segment in
            "\(index + 1)\n\(TimeText.srt(segment.start)) --> \(TimeText.srt(segment.end))\n\(segment.text)\n"
        }.joined(separator: "\n")
    }
}
