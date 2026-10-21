import Foundation
import CryptoKit

/// Sparse, source-anchored edits. A model never owns the transcript or its timeline.
public enum LectureReview {
    public struct ValidationError: LocalizedError {
        public let code: String
        public var errorDescription: String? { "Final review rejected: " + code }
    }
    public struct Evidence: Codable, Equatable, Sendable {
        public let segmentID: Int
        public let quote: String
    }
    public struct Edit: Codable, Equatable, Sendable {
        public let segmentID: Int
        public let before: String
        public let after: String
        public let kind: String
        public let evidence: [Evidence]
    }
    public struct Proposal: Codable, Sendable {
        public let complete: Bool
        public let edits: [Edit]
    }
    public struct Term: Codable, Sendable {
        public let term: String
        public let evidence: [Evidence]
    }
    public struct Request {
        public let instructions: String
        public let input: Data
        public let schema: Data
    }
    public struct Outcome {
        public let segments: [TranscriptSegment]
        public let changedSegments: Int
        public let edits: Int
        public let cached: Bool
        public let preservedSegments: Int
    }
    private struct Rejection: Codable {
        let segmentID: Int
        let code: String
    }
    private struct BatchReceipt: Codable {
        let targetIDs: [Int]
        let proposal: Proposal
        let rejected: [Rejection]
    }
    private struct Receipt: Codable {
        let fingerprint: String
        let promptVersion: String
        let model: String
        let effort: String
        let proposals: [Proposal]
        let rejected: [Rejection]
    }
    public static let model = "gpt-6.1-sol"
    public static let effort = "medium"
    private static let maximumInput = 180_000

    public static func apply(_ proposal: Proposal, to source: [TranscriptSegment],
                             editableIDs: Set<Int>? = nil) throws -> [TranscriptSegment] {
        guard proposal.complete, proposal.edits.count <= 256,
              Set(source.map(\.id)).count == source.count else { throw invalid("incomplete_or_duplicate_source") }
        let byID = Dictionary(uniqueKeysWithValues: source.map { ($0.id, $0) })
        let allowed = editableIDs ?? Set(byID.keys)
        var changes: [Int: [(NSRange, String)]] = [:]
        for edit in proposal.edits {
            guard allowed.contains(edit.segmentID), let segment = byID[edit.segmentID],
                  !edit.before.isEmpty, !edit.after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  edit.before != edit.after, edit.before.count <= 80, edit.after.count <= 80,
                  !edit.after.contains(where: { $0.isNewline }),
                  edit.after.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
                throw invalid("edit_scope")
            }
            let original = segment.text as NSString
            let range = original.range(of: edit.before)
            guard range.location != NSNotFound else { throw invalid("source_mismatch") }
            let remainder = NSRange(location: range.location + 1, length: original.length - range.location - 1)
            guard original.range(of: edit.before, range: remainder).location == NSNotFound else {
                throw invalid("ambiguous_source")
            }
            guard protected(edit.before) == protected(edit.after) else { throw invalid("protected_content") }
            switch edit.kind {
            case "spacing":
                guard compact(edit.before) == compact(edit.after), edit.evidence.isEmpty else { throw invalid("not_spacing") }
            case "punctuation":
                guard letters(edit.before) == letters(edit.after), edit.evidence.isEmpty,
                      punctuationSemantics(edit.before) == punctuationSemantics(edit.after) else { throw invalid("not_punctuation") }
            case "recognition":
                guard edit.before.count <= 40, edit.after.count <= 40,
                      punctuationSemantics(edit.before) == punctuationSemantics(edit.after),
                      letters(edit.before).count >= 2,
                      editDistance(letters(edit.before), letters(edit.after)) <= max(1, Int(Double(letters(edit.before).count) * 0.6)),
                      Set(edit.evidence.map(\.segmentID)).count >= 2, edit.evidence.count <= 3,
                      edit.evidence.allSatisfy({ $0.segmentID != edit.segmentID && valid($0, in: byID)
                          && compact($0.quote).contains(compact(edit.after)) }) else { throw invalid("unsupported_recognition") }
            default: throw invalid("unknown_kind")
            }
            for (prior, _) in changes[edit.segmentID, default: []] {
                guard NSIntersectionRange(prior, range).length == 0 else { throw invalid("overlapping_edits") }
            }
            changes[edit.segmentID, default: []].append((range, edit.after))
        }
        return try source.map { segment in
            guard let edits = changes[segment.id] else { return segment }
            let edited = NSMutableString(string: segment.text)
            for (range, replacement) in edits.sorted(by: { $0.0.location > $1.0.location }) {
                edited.replaceCharacters(in: range, with: replacement)
            }
            let value = edited as String
            // Many individually small edits must not add up to rewriting a sentence.
            guard protected(segment.text) == protected(value),
                  editDistance(letters(segment.text), letters(value)) <= max(2, Int(Double(letters(segment.text).count) * 0.3)),
                  value.count >= max(1, segment.text.count / 2), value.count <= segment.text.count * 2 + 8 else {
                throw invalid("aggregate_rewrite")
            }
            var result = segment
            result.text = value
            return result
        }
    }

    public static func decode(_ data: Data) throws -> Proposal {
        let object = try strictObject(data, keys: ["complete", "edits"])
        guard let edits = object["edits"] as? [[String: Any]], edits.count <= 256 else { throw invalid("response_shape") }
        for edit in edits {
            guard Set(edit.keys) == ["segmentID", "before", "after", "kind", "evidence"] else { throw invalid("unexpected_field") }
            try checkEvidenceShape(edit["evidence"])
        }
        return try JSONDecoder().decode(Proposal.self, from: data)
    }

    /// All batches validate against the same immutable input. Only the complete revision is committed.
    public static func review(_ source: [TranscriptSegment], cacheURL: URL,
                              request: (Request) async throws -> Data) async throws -> Outcome {
        guard !source.isEmpty, source.count <= 20_000, Set(source.map(\.id)).count == source.count,
              source.allSatisfy({ !$0.text.isEmpty && $0.text.count <= 4000 && $0.start.isFinite && $0.end.isFinite
                  && $0.start >= 0 && $0.end > $0.start }) else { throw invalid("source_shape") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let sourceData = try encoder.encode(source)
        guard sourceData.count <= 8 * 1024 * 1024 else { throw invalid("source_capacity") }
        let fingerprint = SHA256.hash(data: sourceData).map { String(format: "%02x", $0) }.joined()
        let batches = try TranscriptCorrection.chunks(source, maximumBytes: 16_000, maximumSegments: 48)
        if let size = try? cacheURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4 * 1024 * 1024,
           let data = try? Data(contentsOf: cacheURL), let saved = try? JSONDecoder().decode(Receipt.self, from: data),
           saved.fingerprint == fingerprint, saved.promptVersion == LectureReviewPrompts.version,
           saved.model == model, saved.effort == effort,
           saved.proposals.count == batches.count,
           zip(saved.proposals, batches).allSatisfy({ proposal, batch in
               Set(proposal.edits.map(\.segmentID)).isSubset(of: Set(batch.map(\.id)))
           }),
           let restored = try? combine(saved.proposals, source: source) {
            try Task.checkCancellation()
            return outcome(restored, source: source, edits: saved.proposals.reduce(0) { $0 + $1.edits.count }, cached: true, rejected: saved.rejected)
        }
        let full = try JSONSerialization.jsonObject(with: TranscriptCorrection.input(for: source))
        var context: [String: Any]
        if (try TranscriptCorrection.input(for: source)).count < 125_000 {
            context = ["source": full]
        } else {
            // Visit every part, including the end. Never truncate a lecture to fit context.
            var terms: [Term] = []
            let portions = try TranscriptCorrection.chunks(source, maximumBytes: 120_000, maximumSegments: 1800)
            for portion in portions {
                try Task.checkCancellation()
                let data = try await request(.init(instructions: LectureReviewPrompts.context,
                    input: TranscriptCorrection.input(for: portion), schema: contextSchema(ids: portion.map(\.id))))
                terms += try decodeTerms(data, source: portion)
            }
            var seen: Set<String> = []
            terms = terms.filter { seen.insert($0.term).inserted }
            let data = try encoder.encode(terms)
            guard data.count <= 80_000 else { throw invalid("context_capacity") }
            context = ["terms": try JSONSerialization.jsonObject(with: data), "allPartsReviewed": true]
        }
        var proposals: [Proposal] = []
        var rejections: [Rejection] = []
        let partsRoot = cacheURL.appendingPathExtension("parts")
        // A missing recording directory is a storage failure, not a successful review.
        if !FileManager.default.fileExists(atPath: partsRoot.path) {
            try FileManager.default.createDirectory(at: partsRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let revisionKey = fingerprint + "-" + LectureReviewPrompts.version + "-" + model + "-" + effort
        let parts = partsRoot.appendingPathComponent(revisionKey)
        try FileManager.default.createDirectory(at: parts, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for (batchIndex, batch) in batches.enumerated() {
            try Task.checkCancellation()
            let ids = batch.map(\.id)
            let batchURL = parts.appendingPathComponent("\(batchIndex).json")
            if let size = try? batchURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 160_000,
               let data = try? Data(contentsOf: batchURL), let saved = try? JSONDecoder().decode(BatchReceipt.self, from: data),
               saved.targetIDs == ids, saved.rejected.allSatisfy({ ids.contains($0.segmentID) }),
               (try? apply(saved.proposal, to: source, editableIDs: Set(ids))) != nil {
                proposals.append(saved.proposal); rejections += saved.rejected
                continue
            }
            var payload = context
            payload["editableSegments"] = try JSONSerialization.jsonObject(with: TranscriptCorrection.input(for: batch))
            if context["source"] == nil, let first = source.firstIndex(where: { $0.id == batch[0].id }),
               let last = source.firstIndex(where: { $0.id == batch.last!.id }) {
                payload["nearbySource"] = try JSONSerialization.jsonObject(with:
                    TranscriptCorrection.input(for: Array(source[max(0, first - 3)..<min(source.count, last + 4)])))
            }
            var accepted: Proposal?
            var rejected: [Rejection] = []
            // Retry invalid proposals with specific, non-transcript validation feedback.
            // On a second semantic failure, preserve that entire sentence unchanged.
            // A malformed/incomplete response still cannot count as a reviewed batch.
            for attempt in 0..<2 {
                let input = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                guard input.count <= maximumInput else { throw invalid("request_capacity") }
                let data = try await request(.init(instructions: LectureReviewPrompts.correction,
                    input: input, schema: try schema(ids: ids)))
                try Task.checkCancellation()
                do {
                    let checked = try validated(try decode(data), source: source, ids: Set(ids))
                    if checked.1.isEmpty || attempt == 1 {
                        accepted = checked.0; rejected = checked.1; break
                    }
                    payload["validationFeedback"] = try JSONSerialization.jsonObject(with: encoder.encode(checked.1))
                } catch {
                    if attempt == 1 { throw error }
                    payload["validationFeedback"] = [["code": (error as? ValidationError)?.code ?? "response_shape"]]
                }
            }
            guard let accepted else { throw invalid("missing_proposal") }
            let saved = BatchReceipt(targetIDs: ids, proposal: accepted, rejected: rejected)
            try encoder.encode(saved).write(to: batchURL, options: .atomic)
            proposals.append(accepted); rejections += rejected
        }
        let result = try combine(proposals, source: source)
        try Task.checkCancellation()
        let receipt = Receipt(fingerprint: fingerprint, promptVersion: LectureReviewPrompts.version,
                              model: model, effort: effort, proposals: proposals, rejected: rejections)
        let committed = try encoder.encode(receipt)
        guard committed.count <= 4 * 1024 * 1024 else { throw invalid("revision_capacity") }
        try committed.write(to: cacheURL, options: .atomic)
        return outcome(result, source: source, edits: proposals.reduce(0) { $0 + $1.edits.count }, cached: false, rejected: rejections)
    }

    private static func combine(_ proposals: [Proposal], source: [TranscriptSegment]) throws -> [TranscriptSegment] {
        guard !proposals.isEmpty else { throw invalid("empty_revision") }
        var result = source
        var touched: Set<Int> = []
        for proposal in proposals {
            let IDs = Set(proposal.edits.map(\.segmentID))
            guard touched.isDisjoint(with: IDs) else { throw invalid("cross_batch_edit") }
            let next = try apply(proposal, to: source)
            for index in source.indices where IDs.contains(source[index].id) { result[index] = next[index] }
            touched.formUnion(IDs)
        }
        return result
    }
    private static func validated(_ proposal: Proposal, source: [TranscriptSegment], ids: Set<Int>) throws -> (Proposal, [Rejection]) {
        guard proposal.complete, Set(proposal.edits.map(\.segmentID)).isSubset(of: ids) else { throw invalid("incomplete_or_scope") }
        var accepted: [Edit] = [], rejected: [Rejection] = []
        let groups = Dictionary(grouping: proposal.edits, by: \.segmentID)
        for id in groups.keys.sorted() {
            let edits = groups[id]!
            do {
                _ = try apply(.init(complete: true, edits: edits), to: source, editableIDs: ids)
                accepted += edits
            } catch let error as ValidationError {
                rejected.append(.init(segmentID: id, code: error.code))
            }
        }
        return (.init(complete: true, edits: accepted), rejected)
    }
    private static func outcome(_ result: [TranscriptSegment], source: [TranscriptSegment], edits: Int, cached: Bool,
                                rejected: [Rejection]) -> Outcome {
        .init(segments: result, changedSegments: zip(source, result).filter { $0.text != $1.text }.count,
              edits: edits, cached: cached, preservedSegments: Set(rejected.map(\.segmentID)).count)
    }
    private static func valid(_ evidence: Evidence, in source: [Int: TranscriptSegment]) -> Bool {
        evidence.quote.count >= 2 && evidence.quote.count <= 200 && source[evidence.segmentID]?.text.contains(evidence.quote) == true
    }
    private static func compact(_ value: String) -> String { String(value.filter { !$0.isWhitespace }) }
    private static func letters(_ value: String) -> String {
        String(value.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
    private static func matches(_ pattern: String, _ value: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: pattern)
        let string = value as NSString
        return regex.matches(in: value, range: NSRange(location: 0, length: string.length)).map { string.substring(with: $0.range) }
    }
    private static func protected(_ value: String) -> [String] {
        // Retain signed quantities, decimal/date separators, Latin identifiers and meaning-bearing Korean stems.
        matches(#"[+−-]?(?:\d+(?:[.,:/]\d+)*|[.,]\d+)(?:[%％‰°])?|[A-Za-z][A-Za-z0-9_]*|[영공일이삼사오육칠팔구십백천만억조]+(?=원|달러|년|월|개|명|배|퍼센트|프로|분|초|시간|점|$)|[=<>≤≥±×÷∑√^₩$€£%％]|않|못|아니|없|말고|제외|이상|이하|초과|미만|반드시|아마|불가능|가능|불확실|확실"#, compact(value))
    }
    private static func punctuationSemantics(_ value: String) -> [String] {
        // Do not alter questions, quotes, parentheses, math, or decimal punctuation by calling it formatting.
        value.unicodeScalars.filter {
            !CharacterSet.alphanumerics.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0)
                && !".,!。！、，".unicodeScalars.contains($0)
        }.map(String.init)
    }
    private static func editDistance(_ a: String, _ b: String) -> Int {
        if a == b { return 0 }
        let left = Array(a), right = Array(b)
        var previous = Array(0...right.count)
        for (i, value) in left.enumerated() {
            var row = [i + 1] + Array(repeating: 0, count: right.count)
            for (j, other) in right.enumerated() {
                row[j + 1] = min(row[j] + 1, previous[j + 1] + 1, previous[j] + (value == other ? 0 : 1))
            }
            previous = row
        }
        return previous.last!
    }
    private static func strictObject(_ data: Data, keys: Set<String>) throws -> [String: Any] {
        guard data.count <= 160_000, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == keys else { throw invalid("response_shape") }
        return object
    }
    private static func checkEvidenceShape(_ object: Any?) throws {
        guard let rows = object as? [[String: Any]], rows.count <= 3,
              rows.allSatisfy({ Set($0.keys) == ["segmentID", "quote"] }) else { throw invalid("evidence_shape") }
    }
    private static func decodeTerms(_ data: Data, source: [TranscriptSegment]) throws -> [Term] {
        let object = try strictObject(data, keys: ["complete", "terms"])
        guard let rows = object["terms"] as? [[String: Any]], rows.count <= 80 else { throw invalid("terms_shape") }
        for row in rows {
            guard Set(row.keys) == ["term", "evidence"] else { throw invalid("terms_shape") }
            try checkEvidenceShape(row["evidence"])
        }
        struct Result: Decodable { let complete: Bool; let terms: [Term] }
        let result = try JSONDecoder().decode(Result.self, from: data)
        let byID = Dictionary(uniqueKeysWithValues: source.map { ($0.id, $0) })
        guard result.complete, result.terms.allSatisfy({ term in
            (2...40).contains(term.term.count) && Set(term.evidence.map(\.segmentID)).count >= 2
                && term.evidence.allSatisfy { valid($0, in: byID) && $0.quote.contains(term.term) }
        }) else { throw invalid("unsupported_context") }
        return result.terms
    }
    private static func evidenceSchema() -> [String: Any] {
        ["type": "array", "maxItems": 3, "items": ["type": "object", "additionalProperties": false,
            "required": ["segmentID", "quote"], "properties": ["segmentID": ["type": "integer"],
            "quote": ["type": "string", "minLength": 2, "maxLength": 200]]]]
    }
    public static func schema(ids: [Int]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": "object", "additionalProperties": false,
            "required": ["complete", "edits"], "properties": ["complete": ["type": "boolean"],
            "edits": ["type": "array", "maxItems": 256, "items": ["type": "object", "additionalProperties": false,
                "required": ["segmentID", "before", "after", "kind", "evidence"],
                "properties": ["segmentID": ["type": "integer", "enum": ids],
                    "before": ["type": "string", "minLength": 1, "maxLength": 80],
                    "after": ["type": "string", "minLength": 1, "maxLength": 80],
                    "kind": ["type": "string", "enum": ["spacing", "punctuation", "recognition"]],
                    "evidence": evidenceSchema()]]]]], options: [.sortedKeys])
    }
    private static func contextSchema(ids: [Int]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": "object", "additionalProperties": false,
            "required": ["complete", "terms"], "properties": ["complete": ["type": "boolean"],
            "terms": ["type": "array", "maxItems": 80, "items": ["type": "object", "additionalProperties": false,
                "required": ["term", "evidence"], "properties": ["term": ["type": "string", "minLength": 2, "maxLength": 40],
                "evidence": evidenceSchema()]]]]], options: [.sortedKeys])
    }
    private static func invalid(_ code: String) -> ValidationError { .init(code: code) }
}
