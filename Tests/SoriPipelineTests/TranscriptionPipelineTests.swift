import Foundation
import XCTest
import CryptoKit
import SoriCore
import SoriSpeech
@testable import SoriApp

final class TranscriptionPipelineTests: XCTestCase {
    @MainActor private func fixture() throws -> (URL, URL, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("doongdoong-pipeline-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = root.appendingPathComponent("audio.wav")
        var data = Data("RIFF".utf8)
        func u32(_ v: UInt32) { var v = v.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var v = v.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        u32(32036); data.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
        data.append(Data("data".utf8)); u32(32000)
        for index in 0..<16000 { u16(UInt16(bitPattern: Int16(sin(Double(index) * 0.1) * 10000))) }
        try data.write(to: audio)
        let receipt = try JSONSerialization.data(withJSONObject: ["strategy": SolTranscription.strategy, "language": "ko", "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()], options: [.sortedKeys])
        try receipt.write(to: root.appendingPathComponent("asr-source.json"))
        let executable = root.appendingPathComponent("aligner")
        let script = #"""
        #!/bin/sh
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --transcript) shift; source="$1" ;;
            --output) shift; output="$1" ;;
          esac
          shift
        done
        cp "$(dirname "$source")/aligned-fixture.json" "$output"
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (root, audio, executable.path)
    }

    @MainActor func testInvalidAlignmentPreservesRawAndDoesNotPublishFalseTimes() async throws {
        let (root, audio, executable) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = try JSONSerialization.data(withJSONObject: ["text": "보관할 전사문"])
        let rawURL = root.appendingPathComponent("asr-original.json")
        try raw.write(to: rawURL)
        try Data("{broken".utf8).write(to: root.appendingPathComponent("aligned-fixture.json"))
        let settings = PipelineSettings(codex: "/usr/bin/false", ffmpeg: "/usr/bin/false", language: "ko", alignmentPython: executable, alignmentModels: root.path)
        do {
            _ = try await TranscriptionPipeline.transcribe(audio: audio, directory: root, duration: 1, settings: settings,
                onTranscribed: { _ in XCTFail("Invalid alignment must not be published") })
            XCTFail("Expected alignment failure")
        } catch {
            XCTAssertEqual(try Data(contentsOf: rawURL), raw)
            XCTAssertTrue(error.localizedDescription.contains("재생 위치"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("aligned-transcript.json").path))
        }
    }

    @MainActor func testCachedLongTranscriptSurvivesAnalysisFailureWithoutReupload() async throws {
        let (root, audio, executable) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let segments = (0..<2100).map { TranscriptSegment(id: $0, start: Double($0 * 2), end: Double($0 * 2 + 1), text: "강의 문장 \($0)") }
        let text = segments.map(\.text).joined(separator: "\n")
        try JSONSerialization.data(withJSONObject: ["text": text]).write(to: root.appendingPathComponent("asr-original.json"))
        let entries = try JSONSerialization.jsonObject(with: JSONEncoder().encode(segments))
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "method": "mms-ctc-forced-alignment", "text": text, "duration": 4200, "segments": entries])
            .write(to: root.appendingPathComponent("aligned-fixture.json"))
        let settings = PipelineSettings(codex: "/usr/bin/false", ffmpeg: "/usr/bin/false", language: "ko", alignmentPython: executable, alignmentModels: root.path)
        var published: [TranscriptSegment] = []
        let result = try await TranscriptionPipeline.transcribe(audio: audio, directory: root, duration: 4200,
            settings: settings, onTranscribed: { published = $0 })
        guard case .transcribed(let saved, _, let warning, _) = result else { return XCTFail("Expected saved transcript") }
        XCTAssertEqual(saved, segments)
        XCTAssertEqual(saved, published)
        XCTAssertNotNil(warning)
        XCTAssertEqual(saved.last?.end, 4199)
    }
}
