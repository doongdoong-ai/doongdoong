import Foundation
import Observation
import SoriCore
import SoriSpeech
import DoongdoongTranscription
import DoongdoongAI
import DoongdoongCodex

@Observable @MainActor
final class AppSettings {
    var language: String { didSet { defaults.set(language, forKey: "language"); refreshSpeechAvailability() } }
    var codexPath: String { didSet { defaults.set(codexPath, forKey: "codexPath"); refreshAIConnection() } }
    var ffmpegPath: String { didSet { defaults.set(ffmpegPath, forKey: "ffmpegPath") } }
    var analysisEnabled: Bool { didSet { defaults.set(analysisEnabled, forKey: "analysisEnabled") } }
    var preferredModelID: String { didSet { defaults.set(preferredModelID, forKey: "codexPreferredModel"); selectFromCatalog() } }
    var reasoningEffort: ReasoningEffort { didSet { defaults.set(reasoningEffort.rawValue, forKey: "codexReasoningEffort"); selectFromCatalog() } }
    var requestTimeout: Double { didSet { defaults.set(requestTimeout, forKey: "codexRequestTimeout") } }
    private let defaults: UserDefaults
    private let speechAvailabilityResolver: @Sendable (SpeechConfiguration) async -> SpeechAvailability
    private let catalogResolver: @MainActor (URL) async throws -> CodexCatalog
    private(set) var catalog: CodexCatalog?
    private(set) var lastConnectionCheck: Date?
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
    var availableModels: [CodexModelOption] { catalog?.models ?? [] }
    var availableReasoningEfforts: [ReasoningEffort] {
        let preferred = CodexModel(rawValue: preferredModelID)
        let choices = preferred.map { [$0] } ?? CodexModel.allCases
        return ReasoningEffort.allCases.filter { effort in
            availableModels.contains { choices.contains($0.model) && $0.reasoningEfforts.contains(effort) }
        }
    }
    private func selectFromCatalog() {
        guard let catalog else { return }
        do { connectionState = .ready(try catalog.select(preferred: CodexModel(rawValue: preferredModelID), effort: reasoningEffort)) }
        catch { connectionState = .unavailable }
    }
    var aiConnectionMessage: String {
        switch connectionState {
        case .unchecked: "AI 연결을 확인해 주세요."
        case .checking: "ChatGPT 로그인과 모델 목록을 확인하고 있어요."
        case .ready: "ChatGPT 로그인과 모델 목록을 확인했습니다."
        case .loginRequired: "ChatGPT 계정으로 로그인해 주세요. API 키 로그인은 사용할 수 없습니다."
        case .unavailable: "선택한 모델과 추론 강도를 목록에서 확인하지 못했습니다. 설정을 변경하거나 다시 연결해 주세요."
        case .failed: "AI 연결을 확인하지 못했습니다. 연결 상태를 확인한 뒤 다시 시도해 주세요."
        }
    }

    /// Session-only selection: recheck on every normal app launch and CLI path change.
    @discardableResult func refreshAIConnection() -> Task<Void, Never>? {
        cancelAIConnectionCheck()
        catalog = nil
        guard codexReady else { connectionState = .failed; return nil }
        connectionState = .checking
        let generation = connectionGeneration
        let executable = URL(fileURLWithPath: codexPath)
        let resolve = catalogResolver
        connectionTask = Task { [weak self] in
            let state: AIConnectionState
            var resolved: CodexCatalog?
            do {
                let value = try await resolve(executable)
                resolved = value
                guard let self, self.connectionGeneration == generation, !Task.isCancelled else { return }
                state = .ready(try value.select(preferred: CodexModel(rawValue: self.preferredModelID), effort: self.reasoningEffort))
            }
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
            self.catalog = resolved
            self.lastConnectionCheck = Date()
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
         modelResolver: (@MainActor (URL) async throws -> CodexModel)? = nil,
         catalogResolver: @escaping @MainActor (URL) async throws -> CodexCatalog = { try await CodexModelDiscovery.catalog(executable: $0) },
         speechAvailabilityResolver: @escaping @Sendable (SpeechConfiguration) async -> SpeechAvailability = { await AppleSpeechEngine.availability(configuration: $0) }) {
        self.defaults = defaults
        self.speechAvailabilityResolver = speechAvailabilityResolver
        if let modelResolver {
            self.catalogResolver = { url in .init(models: [.init(model: try await modelResolver(url), reasoningEfforts: [.medium])]) }
        } else { self.catalogResolver = catalogResolver }
        if let legacy = UserDefaults(suiteName: "app.sori.mac") {
            for key in ["language", "codexPath", "ffmpegPath"] where defaults.object(forKey: key) == nil {
                if let value = legacy.object(forKey: key) { defaults.set(value, forKey: key) }
            }
        }
        let savedLanguage = defaults.string(forKey: "language") ?? "ko"
        language = savedLanguage == "auto" ? "ko" : savedLanguage
        defaults.set(savedLanguage == "auto" ? "ko" : savedLanguage, forKey: "language")
        codexPath = defaults.string(forKey: "codexPath") ?? Self.find("codex")
        ffmpegPath = defaults.string(forKey: "ffmpegPath") ?? Self.find("ffmpeg")
        analysisEnabled = defaults.object(forKey: "analysisEnabled") == nil || defaults.bool(forKey: "analysisEnabled")
        preferredModelID = defaults.string(forKey: "codexPreferredModel") ?? ""
        reasoningEffort = ReasoningEffort(rawValue: defaults.string(forKey: "codexReasoningEffort") ?? "") ?? .medium
        let timeout = defaults.double(forKey: "codexRequestTimeout")
        requestTimeout = timeout.isFinite && (30...1800).contains(timeout) ? timeout : 300
    }

    static func find(_ name: String) -> String {
        let paths = ["/opt/homebrew/bin", "/usr/local/bin", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path]
        return paths.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/\(name)"
    }

    private(set) var speechAvailability: SpeechAvailability?
    private(set) var speechPreparation: SpeechPreparation?
    private(set) var speechPreparationError: String?
    private var speechTask: Task<Void, Never>?
    private var speechGeneration = UUID()
    var preparingSpeech: Bool { speechPreparation != nil }
    // Unknown/downloadable assets must not block recording or queueing. The core
    // verifies support and prepares assets before touching an unprocessed chunk.
    var transcriptionReady: Bool {
        speechAvailability != .unavailable && speechAvailability != .unsupportedLanguage
    }
    var transcriptionUnavailableReason: String {
        switch speechAvailability {
        case .unavailable: return "이 Mac에서는 Apple 음성 인식을 사용할 수 없습니다. 녹음은 계속 저장됩니다."
        case .unsupportedLanguage: return "선택한 언어를 지원하지 않습니다. 설정에서 녹음 언어를 변경해 주세요."
        default: return "Apple 음성 인식을 준비하고 있어요. 녹음은 계속 저장됩니다."
        }
    }
    var speechStatusMessage: String {
        if let speechPreparationError { return speechPreparationError }
        if let speechPreparation {
            switch speechPreparation {
            case .checking: return "언어 모델을 확인하고 있어요."
            case .downloading: return "음성 인식 언어 모델을 다운로드하고 있어요."
            }
        }
        switch speechAvailability {
        case .ready: return "언어 모델이 준비되어 있습니다. 인터넷 없이 음성을 인식합니다."
        case .downloadRequired: return "처음 사용할 때 언어 모델을 다운로드합니다. 인터넷 연결이 필요합니다."
        case .downloading: return "macOS가 언어 모델을 다운로드하고 있습니다."
        case .unavailable, .unsupportedLanguage: return transcriptionUnavailableReason
        case nil: return "이 Mac의 음성 인식 지원 상태를 확인합니다."
        }
    }
    @discardableResult func refreshSpeechAvailability() -> Task<Void, Never> {
        cancelSpeechPreparation()
        speechAvailability = nil; speechPreparationError = nil
        let generation = speechGeneration, configuration = SpeechConfiguration(language: language)
        let resolve = speechAvailabilityResolver
        let task = Task { [weak self] in
            let status = await resolve(configuration)
            guard let self, !Task.isCancelled, self.speechGeneration == generation else { return }
            self.speechAvailability = status
        }
        speechTask = task
        return task
    }
    func prepareSpeech() {
        cancelSpeechPreparation()
        speechPreparation = .checking; speechPreparationError = nil
        let generation = speechGeneration, configuration = SpeechConfiguration(language: language)
        speechTask = Task { [weak self] in
            do {
                try await LocalTranscription.engine.prepare(configuration: configuration) { [weak self] progress in
                    await self?.receiveSpeechProgress(progress, generation: generation)
                }
                guard let self, !Task.isCancelled, self.speechGeneration == generation else { return }
                self.speechAvailability = .ready; self.speechPreparation = nil; self.speechTask = nil
            } catch {
                guard let self, !Task.isCancelled, self.speechGeneration == generation else { return }
                self.speechPreparation = nil; self.speechPreparationError = error.localizedDescription; self.speechTask = nil
            }
        }
    }
    func cancelSpeechPreparation() {
        speechGeneration = UUID(); speechTask?.cancel(); speechTask = nil; speechPreparation = nil
    }
    private func receiveSpeechProgress(_ progress: SpeechPreparation, generation: UUID) {
        guard speechGeneration == generation else { return }
        speechPreparation = progress
    }
    var codexReady: Bool { FileManager.default.isExecutableFile(atPath: codexPath) }
    var analysisReady: Bool { analysisEnabled && codexReady && selectedModel != nil }
    var snapshot: PipelineSettings {
        .init(codex: codexPath, ffmpeg: ffmpegPath, language: language, aiModel: analysisEnabled ? selectedModel : nil,
              reasoningEffort: reasoningEffort, requestTimeout: requestTimeout,
              transcription: .init(language: language))
    }
}

struct PipelineSettings: Sendable {
    let codex: String
    let ffmpeg: String
    let language: String
    let aiModel: CodexModel?
    let reasoningEffort: ReasoningEffort
    let requestTimeout: Double
    let transcription: SpeechConfiguration

    init(codex: String, ffmpeg: String, language: String, aiModel: CodexModel? = nil,
         reasoningEffort: ReasoningEffort = .medium, requestTimeout: Double = 300,
         transcription: SpeechConfiguration) {
        self.codex = codex; self.ffmpeg = ffmpeg; self.language = language
        self.aiModel = aiModel; self.transcription = transcription
        self.reasoningEffort = reasoningEffort; self.requestTimeout = requestTimeout
    }

    func requireModel() throws -> CodexModel {
        guard let aiModel else { throw SoriError.message("AI 연결 확인을 마친 뒤 다시 시도해 주세요. 녹음은 보관되어 있습니다.") }
        return aiModel
    }
    @MainActor func makeTextProvider() throws -> any TextGenerationProvider {
        CodexTextProvider(configuration: .init(executable: URL(fileURLWithPath: codex), model: try requireModel(),
            reasoningEffort: reasoningEffort, requestTimeout: requestTimeout))
    }
}
