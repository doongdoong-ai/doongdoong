import Foundation
import XCTest
import SoriCore
@testable import SoriApp

final class TranscriptionPipelineTests: XCTestCase {
    /// Exercise CLI/file boundaries without loading a model or making network requests.
    private func fixture() throws -> (URL, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("doongdoong-pipeline-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("whisper")
        let script = #"""
        #!/bin/sh
        compact=no
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -oj) compact=yes ;;
            -ojf) exit 91 ;;
            -of) shift; output="$1" ;;
            -f) shift; input="$1" ;;
          esac
          shift
        done
        [ "$compact" = yes ] || exit 92
        cp "$input" "$output.json"
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (root, executable.path)
    }

    @MainActor func testMalformedOutputIsPreservedBeforeDecodingFails() async throws {
        let (root, executable) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("audio.wav")
        let raw = Data("{broken".utf8)
        try raw.write(to: audio)
        let settings = PipelineSettings(whisper: executable, model: executable, vadModel: executable,
                                        codex: "/usr/bin/false", ffmpeg: "", language: "ko")
        do {
            _ = try await TranscriptionPipeline.transcribe(audio: audio, directory: root, duration: 4100,
                                                           settings: settings, onTranscribed: { _ in
                XCTFail("Malformed output must never be published")
            })
            XCTFail("Expected transcription failure")
        } catch {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("whisper-original.json")), raw)
            let diagnostic = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("processing.json"))) as? [String: Any]
            XCTAssertEqual(diagnostic?["phase"] as? String, "transcription")
            XCTAssertEqual(diagnostic?["decodingKind"] as? String, "dataCorrupted")
        }
    }

    @MainActor func testLongTranscriptPublishedBeforeCorrectionAndSurvivesItsFailure() async throws {
        let (root, executable) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("audio.wav")
        let entries: [[String: Any]] = (0..<2100).map { index in
            ["offsets": ["from": index * 2000, "to": (index + 1) * 2000], "text": "강의 문장 \(index)"]
        }
        let raw = try JSONSerialization.data(withJSONObject: ["transcription": entries])
        try raw.write(to: audio)
        let settings = PipelineSettings(whisper: executable, model: executable, vadModel: executable,
                                        codex: "/usr/bin/false", ffmpeg: "", language: "ko")
        var published: [TranscriptSegment] = []
        let result = try await TranscriptionPipeline.transcribe(audio: audio, directory: root, duration: 4200,
                                                               settings: settings, onTranscribed: { segments in
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("whisper-original.json")), raw)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("processing.json").path))
            published = segments
        })
        guard case .transcribed(let segments, _, let warning) = result else { return XCTFail("Expected preserved transcript") }
        XCTAssertEqual(segments.count, 2100)
        XCTAssertEqual(segments, published)
        XCTAssertEqual(segments.last?.end, 4200)
        XCTAssertNotNil(warning)
    }
}
