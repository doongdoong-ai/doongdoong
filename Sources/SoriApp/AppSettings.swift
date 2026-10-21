import Foundation
import Observation

@Observable @MainActor
final class AppSettings {
    var language: String { didSet { defaults.set(language, forKey: "language") } }
    var codexPath: String { didSet { defaults.set(codexPath, forKey: "codexPath") } }
    var ffmpegPath: String { didSet { defaults.set(ffmpegPath, forKey: "ffmpegPath") } }
    var alignmentPython: String { didSet { defaults.set(alignmentPython, forKey: "alignmentPython") } }
    var alignmentModels: String { didSet { defaults.set(alignmentModels, forKey: "alignmentModels") } }
    private let defaults = UserDefaults.standard

    init() {
        if let legacy = UserDefaults(suiteName: "app.sori.mac") {
            for key in ["language", "codexPath", "ffmpegPath"] where defaults.object(forKey: key) == nil {
                if let value = legacy.object(forKey: key) { defaults.set(value, forKey: key) }
            }
        }
        language = defaults.string(forKey: "language") ?? "ko"
        codexPath = defaults.string(forKey: "codexPath") ?? Self.find("codex")
        ffmpegPath = defaults.string(forKey: "ffmpegPath") ?? Self.find("ffmpeg")
        alignmentPython = defaults.string(forKey: "alignmentPython") ?? PipelineSettings.defaultAlignmentRoot.appendingPathComponent("venv/bin/python").path
        alignmentModels = defaults.string(forKey: "alignmentModels") ?? PipelineSettings.defaultAlignmentRoot.appendingPathComponent("models").path
    }

    static func find(_ name: String) -> String {
        let paths = ["/opt/homebrew/bin", "/usr/local/bin", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path]
        return paths.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/\(name)"
    }

    var transcriptionReady: Bool {
        codexReady && FileManager.default.isExecutableFile(atPath: ffmpegPath)
            && FileManager.default.isExecutableFile(atPath: alignmentPython)
            && FileManager.default.isReadableFile(atPath: URL(fileURLWithPath: alignmentModels).appendingPathComponent("hub/checkpoints/model.pt").path)
    }
    var transcriptionUnavailableReason: String {
        if !codexReady { return "AI 연결을 확인해 주세요. 녹음 파일은 계속 저장됩니다." }
        return "따라읽기 준비가 필요합니다. 설치 스크립트를 실행하거나 고급 설정에서 파일 위치를 확인해 주세요. 녹음은 계속 저장됩니다."
    }
    var codexReady: Bool { FileManager.default.isExecutableFile(atPath: codexPath) }
    var snapshot: PipelineSettings {
        .init(codex: codexPath, ffmpeg: ffmpegPath, language: language,
              alignmentPython: (alignmentPython as NSString).expandingTildeInPath,
              alignmentModels: (alignmentModels as NSString).expandingTildeInPath)
    }
}

struct PipelineSettings: Sendable {
    static let defaultAlignmentRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Doongdoong/Alignment", isDirectory: true)
    let codex: String
    let ffmpeg: String
    let language: String
    let alignmentPython: String
    let alignmentModels: String

    init(codex: String, ffmpeg: String, language: String, alignmentPython: String, alignmentModels: String) {
        self.codex = codex; self.ffmpeg = ffmpeg; self.language = language
        self.alignmentPython = alignmentPython; self.alignmentModels = alignmentModels
    }
}
