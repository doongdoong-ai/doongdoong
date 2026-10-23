import Foundation
import CryptoKit
import DoongdoongAI

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
    public struct Request {
        public let instructions: String
        public let input: Data
        public let schema: Data
    }
    public struct Progress: Sendable {
        public enum Phase: Sendable { case context, correction }
        public let phase: Phase
        public let completed: Int
        public let total: Int
        public let attempt: Int
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
    private struct NodeReceipt: Codable {
        let targetIDs: [Int]
        let proposal: Proposal?
        let rejected: [Rejection]
        let split: Bool
    }
    private struct Receipt: Codable {
        let fingerprint: String
        let promptVersion: String
        let model: String
        let effort: String
        let provider: String?
        let proposals: [Proposal]
        let rejected: [Rejection]
    }
    private static let maximumInput = 500_000
    public static let maximumResponseBytes = 1_000_000
    private static let maximumEdits = 4096

    public static func apply(_ proposal: Proposal, to source: [TranscriptSegment],
                             editableIDs: Set<Int>? = nil) throws -> [TranscriptSegment] {
        guard proposal.complete, proposal.edits.count <= maximumEdits,
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
                      editDistance(letters(edit.before), letters(edit.after)) <= max(1,
                        Int(Double(letters(edit.before).count) * (edit.evidence.count >= 2 ? 0.75 : 0.6))),
                      !edit.evidence.isEmpty || preservesUnattestedPredicate(edit.before, edit.after),
                      Set(edit.evidence.map(\.segmentID)).count == edit.evidence.count, edit.evidence.count <= 3,
                      edit.evidence.allSatisfy({ $0.segmentID != edit.segmentID && valid($0, in: byID)
                          && compact($0.quote).contains(compact(edit.after)) }) else { throw invalid("unsupported_recognition") }
                guard !breaksParticle(before: edit.before, after: edit.after,
                                      suffix: original.substring(from: range.location + range.length)) else {
                    throw invalid("particle_agreement")
                }
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
        guard let edits = object["edits"] as? [[String: Any]], edits.count <= maximumEdits else { throw invalid("response_shape") }
        for edit in edits {
            guard Set(edit.keys) == ["segmentID", "before", "after", "kind", "evidence"] else { throw invalid("unexpected_field") }
            try checkEvidenceShape(edit["evidence"])
        }
        return try JSONDecoder().decode(Proposal.self, from: data)
    }

    /// Try the entire lecture first. Only capacity errors create a binary split.
    /// Child receipts remain private until every sentence has been reviewed.
    public static func review(_ source: [TranscriptSegment], cacheURL: URL,
                              identity: TextProviderIdentity,
                              onProgress: ((Progress) async -> Void)? = nil,
                              request: (Request) async throws -> Data) async throws -> Outcome {
        try Task.checkCancellation()
        guard !source.isEmpty, source.count <= 20_000, Set(source.map(\.id)).count == source.count,
              source.allSatisfy({ !$0.text.isEmpty && $0.text.count <= 4000 && $0.start.isFinite && $0.end.isFinite
                  && $0.start >= 0 && $0.end > $0.start }) else { throw invalid("source_shape") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let sourceData = try encoder.encode(source)
        guard sourceData.count <= 8 * 1024 * 1024 else { throw invalid("source_capacity") }
        let fingerprint = SHA256.hash(data: sourceData).map { String(format: "%02x", $0) }.joined()
        if let size = try? cacheURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 8 * 1024 * 1024,
           let data = try? Data(contentsOf: cacheURL), let saved = try? JSONDecoder().decode(Receipt.self, from: data),
           saved.fingerprint == fingerprint, saved.promptVersion == LectureReviewPrompts.version,
           saved.model == identity.model, saved.effort == identity.reasoningEffort,
           saved.provider == identity.provider,
           let restored = try? combine(saved.proposals, source: source) {
            try Task.checkCancellation()
            await onProgress?(.init(phase: .correction, completed: source.count, total: source.count, attempt: 0))
            return outcome(restored, source: source, edits: saved.proposals.reduce(0) { $0 + $1.edits.count }, cached: true, rejected: saved.rejected)
        }
        let partsRoot = cacheURL.appendingPathExtension("parts")
        if !FileManager.default.fileExists(atPath: partsRoot.path) {
            try FileManager.default.createDirectory(at: partsRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let identityHash = SHA256.hash(data: try encoder.encode(identity)).map { String(format: "%02x", $0) }.joined()
        let parts = partsRoot.appendingPathComponent(fingerprint + "-" + LectureReviewPrompts.version + "-" + identityHash)
        try FileManager.default.createDirectory(at: parts, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var completed = 0, requests = 0
        var proposals: [Proposal] = [], rejections: [Rejection] = []

        func accept(_ proposal: Proposal, rejected: [Rejection], count: Int) async {
            proposals.append(proposal); rejections += rejected; completed += count
            await onProgress?(.init(phase: .correction, completed: completed, total: source.count, attempt: 0))
        }
        func visit(_ range: Range<Int>, path: String) async throws {
            try Task.checkCancellation()
            let target = Array(source[range]), ids = target.map(\.id)
            // A few read-only boundary sentences retain context when fallback is necessary.
            let visible = Array(source[max(0, range.lowerBound - 3)..<min(source.count, range.upperBound + 3)])
            let nodeURL = parts.appendingPathComponent(path + ".json")
            var mustSplit = false
            if let size = try? nodeURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maximumResponseBytes + 200_000,
               let data = try? Data(contentsOf: nodeURL), let saved = try? JSONDecoder().decode(NodeReceipt.self, from: data),
               saved.targetIDs == ids {
                if saved.split { mustSplit = true }
                else if let proposal = saved.proposal, saved.rejected.allSatisfy({ ids.contains($0.segmentID) }),
                        (try? apply(proposal, to: visible, editableIDs: Set(ids))) != nil {
                    await accept(proposal, rejected: saved.rejected, count: target.count); return
                }
            }
            if !mustSplit {
                var payload: [String: Any] = ["source": try JSONSerialization.jsonObject(with: TranscriptCorrection.input(for: visible)),
                                             "editableIDs": ids]
                do {
                    for attempt in 1...2 {
                        try Task.checkCancellation()
                        await onProgress?(.init(phase: .correction, completed: completed, total: source.count, attempt: attempt))
                        let input = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                        guard input.count <= maximumInput else { throw TextGenerationError.capacityExceeded }
                        guard requests < 128 else { throw invalid("fallback_exhausted") }
                        requests += 1
                        let data = try await request(.init(instructions: LectureReviewPrompts.correction,
                            input: input, schema: try planSchema(ids: ids)))
                        try Task.checkCancellation()
                        guard data.count <= maximumResponseBytes else { throw TextGenerationError.capacityExceeded }
                        do {
                            let proposal = try decodePlan(data, source: visible)
                            // Explicitly incomplete review is not a successful revision.
                            // Retry once before reducing the scope on output exhaustion.
                            if !proposal.complete {
                                if attempt == 2 { throw TextGenerationError.capacityExceeded }
                                payload["validationFeedback"] = [["code": "incomplete_review"]]
                                continue
                            }
                            let checked = try validated(proposal, source: visible, ids: Set(ids))
                            // Semantic rejections do not invalidate the entire completed review.
                            // Keep independent validated edits and omit rejected proposals.
                            let saved = NodeReceipt(targetIDs: ids, proposal: checked.0, rejected: checked.1, split: false)
                            try encoder.encode(saved).write(to: nodeURL, options: .atomic)
                            await accept(checked.0, rejected: checked.1, count: target.count)
                            return
                        } catch let error as TextGenerationError { throw error }
                        catch {
                            if attempt == 2 { throw error }
                            payload["validationFeedback"] = [["code": (error as? ValidationError)?.code ?? "response_shape"]]
                        }
                    }
                } catch TextGenerationError.capacityExceeded {
                    mustSplit = true
                }
            }
            guard mustSplit, range.count > 1, path.count <= 12 else { throw invalid("fallback_exhausted") }
            try encoder.encode(NodeReceipt(targetIDs: ids, proposal: nil, rejected: [], split: true)).write(to: nodeURL, options: .atomic)
            // Balanced by encoded bytes, always at an existing sentence boundary.
            let sizes = try target.map { try TranscriptCorrection.input(for: [$0]).count }
            let half = sizes.reduce(0, +) / 2
            var accumulated = 0, pivot = 1, closest = Int.max
            for index in 0..<(sizes.count - 1) {
                accumulated += sizes[index]
                if abs(accumulated - half) < closest { closest = abs(accumulated - half); pivot = index + 1 }
            }
            let middle = range.lowerBound + pivot
            try await visit(range.lowerBound..<middle, path: path + "0")
            try await visit(middle..<range.upperBound, path: path + "1")
        }
        try await visit(source.indices, path: "r")
        guard completed == source.count else { throw invalid("incomplete_review") }
        let result = try combine(proposals, source: source)
        try Task.checkCancellation()
        let receipt = Receipt(fingerprint: fingerprint, promptVersion: LectureReviewPrompts.version,
                              model: identity.model, effort: identity.reasoningEffort, provider: identity.provider,
                              proposals: proposals, rejected: rejections)
        let committed = try encoder.encode(receipt)
        guard committed.count <= 8 * 1024 * 1024 else { throw invalid("revision_capacity") }
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
            var candidates: [Edit] = []
            // An invalid proposal must not erase independent valid repairs in the same sentence.
            for edit in edits {
                do {
                    _ = try apply(.init(complete: true, edits: [edit]), to: source, editableIDs: ids)
                    candidates.append(edit)
                } catch let error as ValidationError {
                    rejected.append(.init(segmentID: id, code: error.code))
                }
            }
            if let segment = source.first(where: { $0.id == id }) {
                let text = segment.text as NSString
                let ranges = candidates.map { text.range(of: $0.before) }
                let conflicting = Set(ranges.indices.filter { index in
                    ranges.indices.contains { $0 != index && NSIntersectionRange(ranges[index], ranges[$0]).length > 0 }
                })
                if !conflicting.isEmpty {
                    rejected.append(.init(segmentID: id, code: "overlapping_edits"))
                    candidates = candidates.enumerated().filter { !conflicting.contains($0.offset) }.map(\.element)
                }
            }
            guard !candidates.isEmpty else { continue }
            do {
                _ = try apply(.init(complete: true, edits: candidates), to: source, editableIDs: ids)
                accepted += candidates
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
        matches(#"[+−-]?(?:\d+(?:[.,:/]\d+)*|[.,]\d+)(?:조|억|만|천)?(?:퍼센트|시간|달러|위안|유로|파운드|원|년|월|일|개|명|배|분|초|점|엔|프랑|리라|[%％‰°])?|[A-Za-z][A-Za-z0-9_]*|[영공일이삼사오육칠팔구십백천만억조]+(?=원|달러|년|월|개|명|배|퍼센트|프로|분|초|시간|점)|^[영공일이삼사오육칠팔구십백천만억조]+$|[=<>≤≥±×÷∑√^₩$€£%％]|않|못|아니|없|말고|제외|이상|이하|초과|미만|반드시|아마|불가능|가능|불확실|확실"#, compact(value))
    }
    /// Catch newly broken noun/particle joins without rewriting the user's sentence.
    /// Only unambiguous standalone particles are checked; words beginning with 이/가 are not particles.
    private static func breaksParticle(before: String, after: String, suffix: String) -> Bool {
        func finalConsonant(_ text: String) -> Bool? {
            guard let scalar = text.unicodeScalars.last, (0xAC00...0xD7A3).contains(scalar.value) else { return nil }
            return (scalar.value - 0xAC00) % 28 != 0
        }
        guard let old = finalConsonant(before), let new = finalConsonant(after), old != new,
              let particle = matches(#"^(?:은|는|이|가|을|를|과|와)(?=\s|[.,!?。]|$)"#, suffix).first else { return false }
        let requiresConsonant = ["은", "이", "을", "과"].contains(particle)
        return old == requiresConsonant && new != requiresConsonant
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
        return distance(Array(a), Array(b))
    }
    /// Shared verb endings and unchanged neighboring words must not make a new predicate
    /// look like a small spelling fix. This is a conservative guard, not a Korean parser.
    private static func preservesUnattestedPredicate(_ before: String, _ after: String) -> Bool {
        let leftWords = before.split(whereSeparator: \.isWhitespace)
        let rightWords = after.split(whereSeparator: \.isWhitespace)
        guard leftWords.count == rightWords.count else { return true }
        for (leftWord, rightWord) in zip(leftWords, rightWords) where leftWord != rightWord {
            let leftText = letters(String(leftWord)), rightText = letters(String(rightWord))
            let ending = #"(?:하고|하는|해서|하며|하니|합니다|했다|했어요|해요|한다|되고|되는|되어|됩니다|됐어요)$"#
            guard let shared = matches(ending, leftText).first,
                  matches(ending, rightText).first == shared else { continue }
            let left = leftText.decomposedStringWithCanonicalMapping.unicodeScalars.map(\.value)
            let right = rightText.decomposedStringWithCanonicalMapping.unicodeScalars.map(\.value)
            if distance(left, right) > max(1, left.count / 4) { return false }
        }
        return true
    }
    private static func distance<Element: Equatable>(_ left: [Element], _ right: [Element]) -> Int {
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
        guard data.count <= maximumResponseBytes, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == keys else { throw invalid("response_shape") }
        return object
    }
    private static func checkEvidenceShape(_ object: Any?) throws {
        guard let rows = object as? [[String: Any]], rows.count <= 3,
              rows.allSatisfy({ Set($0.keys) == ["segmentID", "quote"] }) else { throw invalid("evidence_shape") }
    }
    private static func evidenceSchema() -> [String: Any] {
        ["type": "array", "maxItems": 3, "items": ["type": "object", "additionalProperties": false,
            "required": ["segmentID", "quote"], "properties": ["segmentID": ["type": "integer"],
            "quote": ["type": "string", "minLength": 2, "maxLength": 200]]]]
    }
    public static func schema(ids: [Int]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": "object", "additionalProperties": false,
            "required": ["complete", "edits"], "properties": ["complete": ["type": "boolean"],
            "edits": ["type": "array", "maxItems": maximumEdits, "items": ["type": "object", "additionalProperties": false,
                "required": ["segmentID", "before", "after", "kind", "evidence"],
                "properties": ["segmentID": ["type": "integer", "enum": ids],
                    "before": ["type": "string", "minLength": 1, "maxLength": 80],
                    "after": ["type": "string", "minLength": 1, "maxLength": 80],
                    "kind": ["type": "string", "enum": ["spacing", "punctuation", "recognition"]],
                    "evidence": evidenceSchema()]]]]], options: [.sortedKeys])
    }
    private static func invalid(_ code: String) -> ValidationError { .init(code: code) }
}
