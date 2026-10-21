import Foundation

/// Compact model output. Repeated repairs share text, but every target remains explicit.
/// The durable receipt uses Edit so provenance and application stay independent of the wire format.
extension LectureReview {
    struct EditGroup: Codable {
        let ids: [Int]
        let before: String
        let after: String
    }
    struct EditPlan: Codable {
        let complete: Bool
        let edits: [EditGroup]
    }

    static func decodePlan(_ data: Data, source: [TranscriptSegment]) throws -> Proposal {
        guard data.count <= maximumResponseBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["complete", "edits"],
              let rows = object["edits"] as? [[String: Any]], rows.count <= 4096,
              rows.allSatisfy({ Set($0.keys) == ["ids", "before", "after"] }) else {
            throw ValidationError(code: "response_shape")
        }
        let plan = try JSONDecoder().decode(EditPlan.self, from: data)
        let compact: (String) -> String = { String($0.filter { !$0.isWhitespace }) }
        let letters: (String) -> String = { String($0.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }) }
        let referenceSource = source.filter { $0.text.count <= 200 }.map { ($0, compact($0.text)) }
        var edits: [Edit] = []
        for group in plan.edits {
            guard !group.ids.isEmpty, Set(group.ids).count == group.ids.count,
                  group.ids.count <= 4096 - edits.count else { throw ValidationError(code: "edit_expansion") }
            let kind = compact(group.before) == compact(group.after) ? "spacing"
                : (letters(group.before) == letters(group.after) ? "punctuation" : "recognition")
            let targetText = compact(group.after)
            let references: [Evidence] = kind == "recognition" ? referenceSource.lazy.filter {
                $0.1.contains(targetText)
            }.prefix(3).map { Evidence(segmentID: $0.0.id, quote: $0.0.text) } : []
            for id in group.ids {
                // References are computed from the immutable source, never invented by the model.
                // They are useful audit evidence, not a requirement that a correct term occur twice.
                let evidence = Array(references.filter { $0.segmentID != id }.prefix(2))
                edits.append(Edit(segmentID: id, before: group.before, after: group.after, kind: kind, evidence: evidence))
            }
        }
        return Proposal(complete: plan.complete, edits: edits)
    }

    static func planSchema(ids: [Int]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": "object", "additionalProperties": false,
            "required": ["complete", "edits"], "properties": ["complete": ["type": "boolean"],
            "edits": ["type": "array", "maxItems": 4096, "items": ["type": "object", "additionalProperties": false,
                "required": ["ids", "before", "after"], "properties": [
                    "ids": ["type": "array", "minItems": 1, "maxItems": 4096,
                            "items": ["type": "integer", "enum": ids]],
                    "before": ["type": "string", "minLength": 1, "maxLength": 80],
                    "after": ["type": "string", "minLength": 1, "maxLength": 80]]]]]], options: [.sortedKeys])
    }
}
