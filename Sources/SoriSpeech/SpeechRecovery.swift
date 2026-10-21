import Foundation
import SoriCore
import DoongdoongCodex

/// Re-listen only where acoustic evidence did not match any transcript sentence.
/// A new ASR response is accepted only after independent alignment within its exact gap.
public enum SpeechRecovery {
    struct Candidate: Codable {
        let startFrame: Int64
        let endFrame: Int64
        let text: String
    }

    @MainActor
    public static func recover(_ report: TranscriptAlignment.Report, audio: URL, directory: URL, workspace: URL,
                               duration: Double, codex: URL, ffmpeg: URL, python: URL,
                               modelDirectory: URL, language: String, selection: CodexModel) async throws -> TranscriptAlignment.Report {
        guard !report.reviewRanges.isEmpty else { return report }
        let recoveryLanguage = Self.recoveryLanguage(requested: language, source: report.segments)
        let fingerprint = try await RecordingChunks.hashFile(audio)
        let root = directory.appendingPathComponent("speech-recovery").appendingPathComponent(fingerprint + "-" + recoveryLanguage + "-v2")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var candidates: [Candidate] = []
        var remaining = min(600.0, max(120.0, duration * 0.1))
        // Always consider the ending, even when earlier noise creates many suspected gaps.
        let ordered = report.reviewRanges.suffix(1) + report.reviewRanges.dropLast()
        for range in ordered.prefix(64) {
            try Task.checkCancellation()
            let length = range.end - range.start
            guard length >= 0.3, length <= 300, length <= remaining else { continue }
            remaining -= length
            let start = Int64((range.start * 16000).rounded(.up)), end = Int64((range.end * 16000).rounded(.down))
            let folder = root.appendingPathComponent("\(start)-\(end)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let clip = folder.appendingPathComponent("audio.wav"), output = folder.appendingPathComponent("asr.json")
            try RecordingChunks.extract(.init(index: 0, startFrame: start, endFrame: end, quietBoundary: false), from: audio, to: clip)
            let hash = try await RecordingChunks.hashFile(clip)
            let text: String
            if let saved = cachedText(output, audioHash: hash, language: recoveryLanguage) {
                text = saved
            } else {
                let work = workspace.appendingPathComponent("recovery-\(start)")
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                do {
                    text = try await SolTranscription.transcribe(audio: clip, workspace: work, output: output,
                        codex: codex, ffmpeg: ffmpeg, language: recoveryLanguage, selection: selection)
                } catch {
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    // A failed recovery is never allowed to discard the main transcript.
                    // Stop remote attempts on auth, transport or quota failures.
                    if let error = error as? DictationError {
                        switch error {
                        case .empty, .invalidResponse: continue
                        default: return report
                        }
                    }
                    return report
                }
            }
            // A tiny Korean gap can be decoded as an unrelated English word even
            // with a language hint. Keep that response for inspection, but do not
            // insert it automatically. Real English-only terms remain reviewable.
            guard acceptsLanguage(text, hint: recoveryLanguage) else { continue }
            candidates.append(.init(startFrame: start, endFrame: end, text: text))
        }
        guard !candidates.isEmpty else { return report }
        candidates.sort { $0.startFrame < $1.startFrame }
        struct Input: Encodable { let text: String; let regions: [Candidate] }
        let text = candidates.map(\.text).joined(separator: "\n")
        let input = root.appendingPathComponent("candidates.json")
        try JSONEncoder().encode(Input(text: text, regions: candidates)).write(to: input, options: .atomic)
        let aligned: TranscriptAlignment.Report
        do {
            aligned = try await TranscriptAlignment.align(audio: audio, transcript: input, text: text, duration: duration,
                python: python, modelDirectory: modelDirectory, workspace: workspace, language: recoveryLanguage,
                output: root.appendingPathComponent("aligned-candidates.json"), regions: true,
                cacheDirectory: directory.appendingPathComponent("alignment-cache"))
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            return report
        }
        return try merge(report, candidates: candidates, aligned: aligned)
    }

    static func merge(_ original: TranscriptAlignment.Report, candidates: [Candidate],
                      aligned: TranscriptAlignment.Report) throws -> TranscriptAlignment.Report {
        var segments = original.segments
        var unresolved = original.reviewRanges
        let compact: (String) -> String = { String($0.filter { !$0.isWhitespace }) }
        for candidate in candidates {
            let start = Double(candidate.startFrame) / 16000, end = Double(candidate.endFrame) / 16000
            let matched = aligned.segments.filter { $0.start >= start - 0.001 && $0.end <= end + 0.001 }
            guard !matched.isEmpty, matched.allSatisfy(\.hasReliableTiming),
                  compact(matched.map(\.text).joined()) == compact(candidate.text),
                  !aligned.reviewRanges.contains(where: { $0.start < end && $0.end > start }),
                  let gap = unresolved.firstIndex(where: { abs($0.start - start) < 0.001 && abs($0.end - end) < 0.001 }) else { continue }
            segments += matched
            unresolved.remove(at: gap)
        }
        segments.sort { $0.start < $1.start }
        var previous = 0.0
        for index in segments.indices {
            guard segments[index].start >= previous, segments[index].end > segments[index].start else {
                throw SoriError.message("재처리한 음성의 위치가 기존 문장과 겹칩니다.")
            }
            segments[index].id = index; previous = segments[index].end
        }
        return .init(segments: segments, reviewRanges: unresolved)
    }

    static func recoveryLanguage(requested: String, source: [TranscriptSegment]) -> String {
        guard requested == "auto" else { return requested }
        let letters = source.map(\.originalText).joined().unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let hangul = letters.filter { (0xAC00...0xD7A3).contains($0.value) }.count
        // Tiny clips otherwise lose the language evidence available in the full lecture.
        // This is only a language hint; it never translates or rewrites returned text.
        return hangul > 20 && hangul * 2 > letters.count ? "ko" : "auto"
    }

    static func acceptsLanguage(_ text: String, hint: String) -> Bool {
        guard hint == "ko" else { return true }
        return text.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) }
    }

    private static func cachedText(_ url: URL, audioHash: String, language: String) -> String? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4 * 1024 * 1024,
              let data = try? Data(contentsOf: url), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let manifest = object["manifest"] as? [String: Any], manifest["audioSHA256"] as? String == audioHash,
              manifest["language"] as? String == language, manifest["strategy"] as? String == RecordingChunks.strategy,
              let text = object["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}
