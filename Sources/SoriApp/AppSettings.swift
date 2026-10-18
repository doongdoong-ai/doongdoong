import Foundation
import Observation

@Observable @MainActor
final class AppSettings {
    var language: String { didSet { defaults.set(language, forKey: "language") } }
    var whisperPath: String { didSet { defaults.set(whisperPath, forKey: "whisperPath") } }
    var modelPath: String { didSet { defaults.set(modelPath, forKey: "modelPath") } }
    var vadModelPath: String { didSet { defaults.set(vadModelPath, forKey: "vadModelPath") } }
    var codexPath: String { didSet { defaults.set(codexPath, forKey: "codexPath") } }
    var ffmpegPath: String { didSet { defaults.set(ffmpegPath, forKey: "ffmpegPath") } }
    private let defaults = UserDefaults.standard

    init() {
        // Preserve preferences when upgrading from the early Sori bundle identifier.
        if let legacy = UserDefaults(suiteName: "app.sori.mac") {
            for key in ["language", "whisperPath", "modelPath", "vadModelPath", "codexPath", "ffmpegPath"] where defaults.object(forKey: key) == nil {
                if let value = legacy.object(forKey: key) { defaults.set(value, forKey: key) }
            }
        }
        language = defaults.string(forKey: "language") ?? "ko"
        whisperPath = defaults.string(forKey: "whisperPath") ?? Self.find("whisper-cli")
        let savedModelPath = defaults.string(forKey: "modelPath")
        let selectedModelPath = Self.resolvedModelPath(savedModelPath)
        modelPath = selectedModelPath
        vadModelPath = Self.resolvedVADModelPath(defaults.string(forKey: "vadModelPath"))
        codexPath = defaults.string(forKey: "codexPath") ?? Self.find("codex")
        ffmpegPath = defaults.string(forKey: "ffmpegPath") ?? Self.find("ffmpeg")
        if selectedModelPath != savedModelPath { defaults.set(selectedModelPath, forKey: "modelPath") }
    }
    static func find(_ name: String) -> String {
        let paths = ["/opt/homebrew/bin", "/usr/local/bin", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path]
        return paths.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/\(name)"
    }
    static func resolvedModelPath(_ savedPath: String?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let models = home.appendingPathComponent("Library/Application Support/Sori/Models", isDirectory: true)
        let preferred = models.appendingPathComponent("ggml-large-v3-turbo.bin").path
        guard let savedPath, !savedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return preferred }
        let expanded = (savedPath as NSString).expandingTildeInPath
        let previousDefault = models.appendingPathComponent("ggml-small.bin").standardizedFileURL.path
        // Only migrate the previous default. A model selected elsewhere remains the user's choice.
        return URL(fileURLWithPath: expanded).standardizedFileURL.path == previousDefault ? preferred : expanded
    }

    static func resolvedVADModelPath(_ savedPath: String?) -> String {
        guard let savedPath, !savedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return PipelineSettings.defaultVADModelPath
        }
        return (savedPath as NSString).expandingTildeInPath
    }

    private static func readableModel(at path: String) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).resolvingSymlinksInPath()
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        return values?.isRegularFile == true && FileManager.default.isReadableFile(atPath: url.path)
    }

    private var modelsReady: Bool {
        Self.readableModel(at: modelPath) && Self.readableModel(at: vadModelPath)
    }

    // Local readiness is independent of account authentication, checked for every AI job.
    var transcriptionReady: Bool {
        FileManager.default.isExecutableFile(atPath: whisperPath)
            && modelsReady
            && codexReady
    }
    var transcriptionUnavailableReason: String {
        if !FileManager.default.isExecutableFile(atPath: whisperPath) || !modelsReady {
            return "AI 준비가 필요합니다. 고급 설정에서 준비 파일의 위치를 확인해 주세요. 녹음 파일은 계속 저장됩니다."
        }
        return "AI 연결을 확인해 주세요. 녹음 파일은 계속 저장됩니다."
    }
    /// Whether the configured CLI exists; this does not imply login or audio support.
    var codexReady: Bool { FileManager.default.isExecutableFile(atPath: codexPath) }
    var snapshot: PipelineSettings {
        .init(whisper: whisperPath,
              model: (modelPath as NSString).expandingTildeInPath,
              vadModel: (vadModelPath as NSString).expandingTildeInPath,
              codex: codexPath, ffmpeg: ffmpegPath, language: language)
    }
}

struct PipelineSettings: Sendable {
    static let defaultVADModelPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Sori/Models/ggml-silero-v6.2.0.bin").path

    let whisper: String
    let model: String
    let vadModel: String
    let codex: String
    let ffmpeg: String
    let language: String

    init(whisper: String, model: String, vadModel: String = PipelineSettings.defaultVADModelPath,
         codex: String, ffmpeg: String, language: String) {
        self.whisper = whisper
        self.model = model
        self.vadModel = vadModel
        self.codex = codex
        self.ffmpeg = ffmpeg
        self.language = language
    }
}
