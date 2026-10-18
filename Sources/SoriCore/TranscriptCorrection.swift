import Foundation

/// Keeps model context bounded without splitting a timed segment or renumbering IDs.
public enum TranscriptCorrection {
    private struct Input: Encodable {
        struct Segment: Encodable { let id: Int; let text: String }
        let segments: [Segment]
    }

    public static func input(for segments: [TranscriptSegment]) throws -> Data {
        try JSONEncoder().encode(Input(segments: segments.map { .init(id: $0.id, text: $0.text) }))
    }

    public static func chunks(_ segments: [TranscriptSegment], maximumBytes: Int = 24_000,
                              maximumSegments: Int = 48) throws -> [[TranscriptSegment]] {
        guard maximumBytes > 0, maximumSegments > 0,
              Set(segments.map(\.id)).count == segments.count else {
            throw SoriError.message("Invalid transcript correction input")
        }
        var result: [[TranscriptSegment]] = [], pending: [TranscriptSegment] = []
        for segment in segments {
            let candidate = pending + [segment]
            let exceedsBytes = try input(for: candidate).count > maximumBytes
            if candidate.count > maximumSegments || exceedsBytes {
                if !pending.isEmpty { result.append(pending); pending = [] }
                guard (try input(for: [segment])).count <= maximumBytes else {
                    throw SoriError.message("A transcript segment exceeds the correction input limit")
                }
            }
            pending.append(segment)
        }
        if !pending.isEmpty { result.append(pending) }
        return result
    }

    /// Validation is deliberately conservative: spelling and punctuation edits are allowed,
    /// but summaries, missing IDs, and unexpectedly expanded responses keep the original.
    public static func apply(_ data: Data, to source: [TranscriptSegment]) throws -> [TranscriptSegment] {
        guard data.count <= 256_000 else { throw SoriError.message("Correction response exceeds its size limit") }
        let corrected = try Transcript.applyCorrections(data, to: source)
        for (before, after) in zip(source, corrected) {
            guard before.id == after.id, before.start == after.start, before.end == after.end,
                  before.originalText == after.originalText,
                  after.text.count <= max(160, before.text.count * 2),
                  after.text.count >= max(1, before.text.count / 2) else {
                throw SoriError.message("Correction changed transcript identity, timing, or length excessively")
            }
        }
        return corrected
    }

    public static func schema(for segments: [TranscriptSegment]) throws -> Data {
        let schema: [String: Any] = [
            "type": "object", "additionalProperties": false, "required": ["segments"],
            "properties": ["segments": [
                "type": "array", "minItems": segments.count, "maxItems": segments.count,
                "items": ["type": "object", "additionalProperties": false, "required": ["id", "text"],
                          "properties": ["id": ["type": "integer", "enum": segments.map(\.id)],
                                         "text": ["type": "string", "minLength": 1]]]
            ]]
        ]
        return try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
    }
}
