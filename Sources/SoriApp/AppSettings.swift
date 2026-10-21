import Foundation
import Observation
import SoriCore
import SoriSpeech
import DoongdoongTranscription

@Observable @MainActor
final class AppSettings {
    var language: String { didSet { defaults.set(language, forKey: "language") } }
    var codexPath: String { didSet { defaults.set(codexPath, forKey: "codexPath"); refreshAIConnection() } }
    var ffmpegPath: String { didSet { defaults.set(ffmpegPath, forKey: "ffmpegPath") } }
    var whisperPath: String { didSet { defaults.set(whisperPath, forKey: "whisperPath") } }
    var whisperModel: String { didSet { defaults.set(whisperModel, forKey: "whisperModel") } }
    var vadModel: String { didSet { defaults.set(vadModel, forKey: "vadModel") } }
    private let defaults: UserDefaults
    private let modelResolver: @MainActor (URL) async throws -> CodexModel
    private(set) var connectionState: AIConnectionState = .unchecked
    private var connectionTask: Task<Void, Never>?
    private var connectionGeneration = UUID()

    enum AIConnectionState: Equatable {
        case unchecked, checking, ready(CodexModel), loginRequired, unavailable, failed
    }
    var selectedModel: CodexModel? {
        if case .ready(let model) = connectionState { return model }
        return nil
    }
    var checkingAI: Bool { connectionState == .checking }
    var aiConnectionMessage: String {
        switch connectionState {
        case .unchecked: "AI 연결을 확인해 주세요."
        case .checking: "계정에서 사용할 수 있는 AI를 확인하고 있어요."
        case .ready: "AI 연결이 확인되었습니다."
        case .loginRequired: "ChatGPT 계정으로 로그인해 주세요. API 키 로그인은 사용할 수 없습니다."
        case .unavailable: "현재 계정과 CLI에서 지원하는 AI를 찾지 못했습니다. 녹음은 계속 저장됩니다."
        case .failed: "AI 연결을 확인하지 못했습니다. 연결 상태를 확인한 뒤 다시 시도해 주세요."
        }
    }

    /// Session-only selection: recheck on every normal app launch and CLI path change.
    @discardableResult func refreshAIConnection() -> Task<Void, Never>? {
        cancelAIConnectionCheck()
        guard codexReady else { connectionState = .failed; return nil }
        connectionState = .checking
        let generation = connectionGeneration
        let executable = URL(fileURLWithPath: codexPath)
        let resolve = modelResolver
        connectionTask = Task { [weak self] in
            let state: AIConnectionState
            do { state = .ready(try await resolve(executable)) }
            catch {
                if Task.isCancelled || error is CancellationError { return }
                switch error as? CodexModelDiscovery.DiscoveryError {
                case .loginRequired: state = .loginRequired
                case .noSupportedModel: state = .unavailable
                default: state = .failed
                }
            }
            guard let self, !Task.isCancelled, self.connectionGeneration == generation else { return }
            self.connectionState = state
            self.connectionTask = nil
        }
        return connectionTask
    }

    func cancelAIConnectionCheck() {
        connectionGeneration = UUID()
        connectionTask?.cancel(); connectionTask = nil
        connectionState = .unchecked
    }

    init(defaults: UserDefaults = .standard,
         modelResolver: @escaping @MainActor (URL) async throws -> CodexModel = { try await CodexModelDiscovery.resolve(executable: $0) }) {
        self.defaults = defaults
        self.modelResolver = modelResolver
        if let legacy = UserDefaults(suiteName: "app.sori.mac") {
            for key in ["language", "codexPath", "ffmpegPath"] where defaults.object(forKey: key) == nil {
                if let value = legacy.object(forKey: key) { defaults.set(value, forKey: key) }
            }
        }
        language = defaults.string(forKey: "language") ?? "ko"
        codexPath = defaults.string(forKey: "codexPath") ?? Self.find("codex")
        ffmpegPath = defaults.string(forKey: "ffmpegPath") ?? Self.find("ffmpeg")
        whisperPath = defaults.string(forKey: "whisperPath") ?? Self.find("whisper-server")
        whisperModel = defaults.string(forKey: "whisperModel") ?? Self.modelPath("ggml-large-v3-turbo.bin")
        vadModel = defaults.string(forKey: "vadModel") ?? Self.modelPath("ggml-silero-v6.2.0.bin")
    }

    static func find(_ name: String) -> String {
        let paths = ["/opt/homebrew/bin", "/usr/local/bin", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path]
        return paths.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/\(name)"
    }

    static func modelPath(_ name: String) -> String {
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let paths = ["Doongdoong/Models", "Sori/Models"].map { support.appendingPathComponent($0).appendingPathComponent(name).path }
        return paths.first { FileManager.default.isReadableFile(atPath: $0) } ?? paths[0]
    }

    var transcriptionReady: Bool {
        FileManager.default.isExecutableFile(atPath: (whisperPath as NSString).expandingTildeInPath)
            && FileManager.default.isReadableFile(atPath: (whisperModel as NSString).expandingTildeInPath)
            && FileManager.default.isReadableFile(atPath: (vadModel as NSString).expandingTildeInPath)
    }
    var transcriptionUnavailableReason: String {
        "음성 인식 준비가 필요합니다. 설치 스크립트를 실행하거나 고급 설정에서 모델 위치를 확인해 주세요. 녹음은 계속 저장됩니다."
    }
    var codexReady: Bool { FileManager.default.isExecutableFile(atPath: codexPath) }
    var analysisReady: Bool { codexReady && selectedModel != nil }
    var snapshot: PipelineSettings {
        .init(codex: codexPath, ffmpeg: ffmpegPath, language: language, aiModel: selectedModel,
              transcription: .init(executable: URL(fileURLWithPath: (whisperPath as NSString).expandingTildeInPath),
                                   model: URL(fileURLWithPath: (whisperModel as NSString).expandingTildeInPath),
                                   vadModel: URL(fileURLWithPath: (vadModel as NSString).expandingTildeInPath), language: language))
    }
}

struct PipelineSettings: Sendable {
    let codex: String
    let ffmpeg: String
    let language: String
    let aiModel: CodexModel?
    let transcription: WhisperConfiguration

    init(codex: String, ffmpeg: String, language: String, aiModel: CodexModel? = nil,
         transcription: WhisperConfiguration) {
        self.codex = codex; self.ffmpeg = ffmpeg; self.language = language
        self.aiModel = aiModel; self.transcription = transcription
    }

    func requireModel() throws -> CodexModel {
        guard let aiModel else { throw SoriError.message("AI 연결 확인을 마친 뒤 다시 시도해 주세요. 녹음은 보관되어 있습니다.") }
        return aiModel
    }
}
