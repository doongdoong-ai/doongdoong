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
    struct ConnectionVerification {
        let catalog: CodexCatalog?
        let result: Result<TextProviderIdentity, ProviderConnectionIssue>
    }
    typealias ConnectionVerifier = @MainActor (URL, String, ReasoningEffort) async throws -> ConnectionVerification
    typealias BrowserLogin = @MainActor (URL, @escaping @MainActor (URL) -> Bool) async throws -> Void
    private let connectionVerifier: ConnectionVerifier
    private let browserLogin: BrowserLogin
    private(set) var catalog: CodexCatalog?
    private(set) var lastConnectionCheck: Date?
    private(set) var connectionState: AIConnectionState = .unchecked
    private var connectionTask: Task<Void, Never>?
    private var connectionGeneration = UUID()
    var showConnectionSetup = false
    private(set) var hasCompletedAISetup: Bool

    enum AIConnectionState: Equatable {
        case unchecked, checking, signingIn, ready(CodexModel), blocked(ProviderConnectionIssue)
    }
    var connectionIssue: ProviderConnectionIssue? {
        if case .blocked(let issue) = connectionState { return issue }
        return nil
    }
    var selectedModel: CodexModel? {
        if case .ready(let model) = connectionState { return model }
        return nil
    }
    var checkingAI: Bool { connectionState == .checking || connectionState == .signingIn }
    var availableModels: [CodexModelOption] { catalog?.models ?? [] }
    var availableReasoningEfforts: [ReasoningEffort] {
        let preferred = CodexModel(rawValue: preferredModelID)
        let choices = preferred.map { [$0] } ?? CodexModel.allCases
        return ReasoningEffort.allCases.filter { effort in
            availableModels.contains { choices.contains($0.model) && $0.reasoningEfforts.contains(effort) }
        }
    }
    private func selectFromCatalog() {
        // Catalog membership cannot verify the newly selected configuration.
        // Invalidate immediately; the user can explicitly check the new choice.
        cancelAIConnectionCheck()
    }
    var aiConnectionMessage: String { AIConnectionPresentation(state: connectionState).message }

    /// One bounded check per launch or explicit retry, never a retry loop.
    @discardableResult func refreshAIConnection(presentOnFailure: Bool = false) -> Task<Void, Never>? {
        cancelAIConnectionCheck()
        connectionState = .checking
        catalog = nil
        let generation = connectionGeneration
        let executable = URL(fileURLWithPath: codexPath), preferred = preferredModelID, effort = reasoningEffort
        let verify = connectionVerifier
        connectionTask = Task { [weak self] in
            let verification: ConnectionVerification
            do { verification = try await verify(executable, preferred, effort) }
            catch {
                guard let self, self.connectionGeneration == generation else { return }
                self.connectionTask = nil
                if Task.isCancelled || error is CancellationError { self.connectionState = .unchecked; return }
                // Defensive boundary for future providers violating the typed contract.
                self.connectionState = .blocked((error as? ProviderConnectionIssue) ?? .init(.unknown, stage: .probe))
                self.lastConnectionCheck = Date()
                if presentOnFailure && self.analysisEnabled { self.showConnectionSetup = true }
                return
            }
            guard let self, !Task.isCancelled, self.connectionGeneration == generation else { return }
            self.catalog = verification.catalog
            switch verification.result {
            case .success(let identity):
                guard identity.provider == "codex", identity.reasoningEffort == effort.rawValue,
                      let model = CodexModel(rawValue: identity.model),
                      preferred.isEmpty || preferred == identity.model else {
                    self.connectionState = .blocked(.init(.invalidResponse, stage: .probe))
                    if presentOnFailure && self.analysisEnabled { self.showConnectionSetup = true }
                    self.connectionTask = nil; return
                }
                self.connectionState = .ready(model)
                self.hasCompletedAISetup = true
                self.defaults.set(true, forKey: "aiSetup.codex.completed")
            case .failure(let issue):
                self.connectionState = .blocked(issue)
                if presentOnFailure && self.analysisEnabled { self.showConnectionSetup = true }
            }
            self.lastConnectionCheck = Date(); self.connectionTask = nil
        }
        return connectionTask
    }

    @discardableResult func signIn(openBrowser: @escaping @MainActor (URL) -> Bool) -> Task<Void, Never> {
        cancelAIConnectionCheck()
        connectionState = .signingIn
        let generation = connectionGeneration, executable = URL(fileURLWithPath: codexPath), login = browserLogin
        let task = Task { [weak self] in
            do {
                try await login(executable, openBrowser)
                guard let self, !Task.isCancelled, self.connectionGeneration == generation else { return }
                // A browser callback alone never marks setup complete.
                self.connectionTask = nil
                await self.refreshAIConnection()?.value
            } catch {
                guard let self, self.connectionGeneration == generation else { return }
                self.connectionTask = nil
                if Task.isCancelled || error is CancellationError { self.connectionState = .unchecked; return }
                self.connectionState = .blocked((error as? ProviderConnectionIssue) ?? .init(.unknown, stage: .login))
            }
        }
        connectionTask = task
        return task
    }

    func presentConnectionSetup() {
        showConnectionSetup = true
        if connectionState == .unchecked || (selectedModel != nil && !codexReady) { refreshAIConnection() }
    }
    func dismissConnectionSetup() {
        if checkingAI { cancelAIConnectionCheck() }
        showConnectionSetup = false
    }
    func cancelAIConnectionCheck() {
        connectionGeneration = UUID()
        connectionTask?.cancel(); connectionTask = nil
        connectionState = .unchecked
    }

    static func verifyCodex(executable: URL, preferred: String, effort: ReasoningEffort) async throws -> ConnectionVerification {
        if !preferred.isEmpty && CodexModel(rawValue: preferred) == nil {
            return .init(catalog: nil, result: .failure(.init(.configuration, stage: .catalog, retry: .afterUserAction)))
        }
        let connection = CodexConnection(executable: executable, preferredModel: CodexModel(rawValue: preferred), reasoningEffort: effort)
        do {
            let identity = try await connection.verifyConnection()
            return .init(catalog: connection.catalog, result: .success(identity))
        }
        catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            return .init(catalog: connection.catalog, result: .failure((error as? ProviderConnectionIssue) ?? .init(.unknown, stage: .probe)))
        }
    }

    init(defaults: UserDefaults = .standard,
         connectionVerifier: @escaping ConnectionVerifier = AppSettings.verifyCodex,
         browserLogin: @escaping BrowserLogin = { try await CodexBrowserLogin.signIn(executable: $0, openBrowser: $1) },
         speechAvailabilityResolver: @escaping @Sendable (SpeechConfiguration) async -> SpeechAvailability = { await AppleSpeechEngine.availability(configuration: $0) }) {
        self.defaults = defaults
        self.speechAvailabilityResolver = speechAvailabilityResolver
        self.connectionVerifier = connectionVerifier
        self.browserLogin = browserLogin
        hasCompletedAISetup = defaults.bool(forKey: "aiSetup.codex.completed")
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
    var transcriptionConfiguration: SpeechConfiguration { .init(language: language) }

    // Compose a provider from the current vendor settings once per job. Its
    // immutable configuration keeps later UI changes out of the running job.
    func makeTextProvider() -> (any TextGenerationProvider)? {
        guard analysisEnabled, let model = selectedModel else { return nil }
        return CodexTextProvider(configuration: .init(executable: URL(fileURLWithPath: codexPath), model: model,
            reasoningEffort: reasoningEffort, requestTimeout: requestTimeout))
    }
}
