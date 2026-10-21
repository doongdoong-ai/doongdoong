import Foundation
import SoriSpeech
import SoriCore

@main
struct TranscribeCommand {
    @MainActor static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 4 else {
            FileHandle.standardError.write(Data("Usage: DoongdoongTranscribe AUDIO OUTPUT_JSON CODEX FFMPEG\nSplits one completed recording into files of at most five minutes, resumes saved chunks, and uses the existing ChatGPT login.\n".utf8))
            exit(2)
        }
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("doongdoong-asr-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: workspace) }
            let output = URL(fileURLWithPath: args[1])
            guard !FileManager.default.fileExists(atPath: output.path) else { throw SoriError.message("출력 파일이 이미 존재합니다.") }
            let text = try await SolTranscription.transcribe(audio: URL(fileURLWithPath: args[0]), workspace: workspace,
                output: output, codex: URL(fileURLWithPath: args[2]), ffmpeg: URL(fileURLWithPath: args[3]), language: "ko")
            print("전사 완료 · \(text.count)자 · \(output.path)")
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); exit(1)
        }
    }
}
