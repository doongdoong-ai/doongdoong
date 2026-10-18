import Foundation

public struct LectureHighlight: Codable, Equatable, Sendable, Identifiable {
    public enum Signal: String, Codable, Sendable { case explicit, repeated }
    public struct Evidence: Codable, Equatable, Sendable, Identifiable {
        public let segmentID: Int
        public let quote: String
        public var id: Int { segmentID }
    }
    public let heading: String
    public let summary: String
    public let signal: Signal
    public let evidence: [Evidence]
    public var id: String { "\(evidence.first?.segmentID ?? -1):\(heading)" }
}

public struct LectureInsights: Sendable {
    public let title: String
    public let highlights: [LectureHighlight]
}

/// Topic synthesis is separate from transcript correction. Every card retains
/// verbatim evidence and stable segment IDs; the model never supplies playback times.
public enum LectureAnalysis {
    public struct Draft: Codable, Sendable {
        public let title: String
        public let synopsis: String
        public let highlights: [LectureHighlight]
    }

    public static func schema(for segments: [TranscriptSegment]) throws -> Data {
        let evidence: [String: Any] = [
            "type": "object", "additionalProperties": false, "required": ["segmentID", "quote"],
            "properties": ["segmentID": ["type": "integer", "enum": segments.map(\.id)],
                           "quote": string(min: 4, max: 400)]
        ]
        let card: [String: Any] = [
            "type": "object", "additionalProperties": false,
            "required": ["heading", "summary", "signal", "evidence"],
            "properties": ["heading": string(min: 1, max: 70), "summary": string(min: 1, max: 480),
                           "signal": ["type": "string", "enum": ["explicit", "repeated"]],
                           "evidence": ["type": "array", "minItems": 1, "maxItems": 3, "items": evidence]]
        ]
        return try JSONSerialization.data(withJSONObject: [
            "type": "object", "additionalProperties": false, "required": ["title", "synopsis", "highlights"],
            "properties": ["title": string(min: 1, max: 80), "synopsis": string(min: 1, max: 800),
                           "highlights": ["type": "array", "maxItems": 8, "items": card]]
        ], options: [.sortedKeys])
    }

    public static func decode(_ data: Data, source: [TranscriptSegment]) throws -> Draft {
        guard data.count <= 80_000 else { throw invalidOutput }
        let draft = try JSONDecoder().decode(Draft.self, from: data)
        guard valid(draft.title, maximum: 80), !draft.title.contains(where: \.isNewline),
              valid(draft.synopsis, maximum: 800), draft.highlights.count <= 8,
              Set(draft.highlights.map(\.id)).count == draft.highlights.count else { throw invalidOutput }
        let texts = Dictionary(uniqueKeysWithValues: source.map { ($0.id, $0.text) })
        for card in draft.highlights {
            guard valid(card.heading, maximum: 70), valid(card.summary, maximum: 480),
                  (1...3).contains(card.evidence.count),
                  Set(card.evidence.map(\.segmentID)).count == card.evidence.count,
                  card.signal != .repeated || card.evidence.count >= 2 else { throw invalidOutput }
            for evidence in card.evidence {
                guard valid(evidence.quote, maximum: 400), evidence.quote.count >= 4,
                      let text = texts[evidence.segmentID],
                      normalized(text).contains(normalized(evidence.quote)) else { throw invalidOutput }
            }
        }
        return draft
    }

    public static func synthesisInput(_ drafts: [Draft]) throws -> Data {
        struct Input: Encodable {
            struct Topic: Encodable { let title: String; let synopsis: String }
            struct Candidate: Encodable { let id: Int; let card: LectureHighlight }
            let topics: [Topic]
            let candidates: [Candidate]
        }
        let data = try JSONEncoder().encode(Input(
            topics: drafts.map { .init(title: $0.title, synopsis: $0.synopsis) },
            candidates: drafts.flatMap(\.highlights).enumerated().map { .init(id: $0.offset, card: $0.element) }))
        guard data.count <= 240_000 else { throw invalidOutput }
        return data
    }

    public static func synthesisSchema(candidateCount: Int) throws -> Data {
        var item: [String: Any] = ["type": "integer"]
        if candidateCount > 0 { item["enum"] = Array(0..<candidateCount) }
        return try JSONSerialization.data(withJSONObject: [
            "type": "object", "additionalProperties": false, "required": ["title", "selectedIDs"],
            "properties": ["title": string(min: 1, max: 80),
                           "selectedIDs": ["type": "array", "maxItems": min(12, candidateCount), "items": item]]
        ], options: [.sortedKeys])
    }

    public static func synthesize(_ data: Data, drafts: [Draft]) throws -> LectureInsights {
        struct Selection: Decodable { let title: String; let selectedIDs: [Int] }
        guard data.count <= 16_000 else { throw invalidOutput }
        let selection = try JSONDecoder().decode(Selection.self, from: data)
        let cards = drafts.flatMap(\.highlights)
        guard valid(selection.title, maximum: 80), !selection.title.contains(where: \.isNewline),
              selection.selectedIDs.count <= 12,
              Set(selection.selectedIDs).count == selection.selectedIDs.count,
              selection.selectedIDs.allSatisfy({ cards.indices.contains($0) }) else { throw invalidOutput }
        var seen = Set<String>()
        let selected = selection.selectedIDs.map { cards[$0] }.filter { seen.insert($0.id).inserted }
        return LectureInsights(title: selection.title.trimmingCharacters(in: .whitespacesAndNewlines),
                               highlights: selected.sorted { ($0.evidence.map(\.segmentID).min() ?? 0) < ($1.evidence.map(\.segmentID).min() ?? 0) })
    }

    public static func result(_ draft: Draft) -> LectureInsights {
        LectureInsights(title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
                        highlights: draft.highlights.sorted { ($0.evidence.map(\.segmentID).min() ?? 0) < ($1.evidence.map(\.segmentID).min() ?? 0) })
    }

    private static func valid(_ text: String, maximum: Int) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= maximum
    }
    private static func normalized(_ text: String) -> String { text.filter { !$0.isWhitespace } }
    private static var invalidOutput: SoriError { .message("강의 정리 결과의 형식 또는 발언 근거를 확인하지 못했습니다.") }
    private static func string(min: Int, max: Int) -> [String: Any] {
        ["type": "string", "minLength": min, "maxLength": max]
    }
}
