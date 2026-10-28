import Foundation
import Observation
import SoriCore
import SoriSpeech
import DoongdoongTranscription
import DoongdoongAI
import DoongdoongCodex
import DoongdoongClaude

/// Text-generation vendors. Each keeps its own CLI, login and model settings.
enum AIVendor: String, CaseIterable, Identifiable {
    case codex, claude
    var id: String { rawValue }
    var name: String { self == .codex ? "Codex" : "Claude" }
    var accountName: String { self == .codex ? "ChatGPT" : "Claude" }
    var executableName: String { rawValue }
    var iconResource: String { "\(rawValue)-icon.png" }
    @MainActor var installationCommand: String { self == .codex ? CodexConnection.installationCommand : ClaudeConnection.installationCommand }
}

/// The verified model of the active vendor, ready to compose a provider.
struct AIModelSelection: Equatable {
    let vendor: AIVendor
    let id: String
    let displayName: String
}

@Observable @MainActor
final class AppSettings {
    var language: String { didSet { defaults.set(language, forKey: "language"); refreshSpeechAvailability() } }
    var vendor: AIVendor { didSet { defaults.set(vendor.rawValue, forKey: "aiVendor"); switchVendor(from: oldValue) } }
    var codexPath: String { didSet { defaults.set(codexPath, forKey: "codexPath"); vendorSettingsChanged(.codex, recheck: true) } }
    var claudePath: String { didSet { defaults.set(claudePath, forKey: "claudePath"); vendorSettingsChanged(.claude, recheck: true) } }
    var ffmpegPath: String { didSet { defaults.set(ffmpegPath, forKey: "ffmpegPath") } }
    var analysisEnabled: Bool { didSet { defaults.set(analysisEnabled, forKey: "analysisEnabled") } }
    var preferredModelID: String { didSet { defaults.set(preferredModelID, forKey: "codexPreferredModel"); vendorSettingsChanged(.codex) } }
    var reasoningEffort: ReasoningEffort { didSet { defaults.set(reasoningEffort.rawValue, forKey: "codexReasoningEffort"); vendorSettingsChanged(.codex) } }
    var claudeEffort: ClaudeEffort { didSet { defaults.set(claudeEffort.rawValue, forKey: "claudeEffort"); vendorSettingsChanged(.claude) } }
    var requestTimeout: Double { didSet { defaults.set(requestTimeout, forKey: "codexRequestTimeout") } }
    private let defaults: UserDefaults
    private let speechAvailabilityResolver: @Sendable (SpeechConfiguration) async -> SpeechAvailability
    struct ConnectionVerification {
        let catalog: CodexCatalog?
        let result: Result<TextProviderIdentity, ProviderConnectionIssue>
        /// The concrete model an alias resolved to, when the vendor reports it.
        var modelName: String? = nil
    }
    typealias ConnectionVerifier = @MainActor (URL, String, ReasoningEffort) async throws -> ConnectionVerification
    typealias ClaudeVerifier = @MainActor (URL, ClaudeEffort) async throws -> ConnectionVerification
    typealias BrowserLogin = @MainActor (URL, @escaping @MainActor (URL) -> Bool) async throws -> Void
    typealias ClaudeLogin = @MainActor (URL) async throws -> Void
    private let connectionVerifier: ConnectionVerifier
    private let claudeVerifier: ClaudeVerifier
    private let browserLogin: BrowserLogin
    private let claudeLogin: ClaudeLogin
    private(set) var catalog: CodexCatalog?
    private(set) var lastConnectionCheck: Date?
    private(set) var connectionState: AIConnectionState = .unchecked
    private var connectionTask: Task<Void, Never>?
    private var connectionGeneration = UUID()
    /// Settled results of vendors that are not active, so switching back is instant.
    private var settled: [AIVendor: SettledConnection] = [:]
    private struct SettledConnection { let state: AIConnectionState; let checked: Date?; let catalog: CodexCatalog? }
    var showConnectionSetup = false
    private(set) var hasCompletedAISetup: Bool

    enum AIConnectionState: Equatable {
        case unchecked, checking, signingIn, ready(AIModelSelection), blocked(ProviderConnectionIssue)
    }
    var connectionIssue: ProviderConnectionIssue? {
        if case .blocked(let issue) = connectionState { return issue }
        return nil
    }
    var selectedModel: AIModelSelection? {
        if case .ready(let model) = connectionState { return model }
        return nil
    }
    func executablePath(for vendor: AIVendor) -> String { vendor == .codex ? codexPath : claudePath }
    func isInstalled(_ vendor: AIVendor) -> Bool { FileManager.default.isExecutableFile(atPath: executablePath(for: vendor)) }
    /// Last known state of any vendor without starting a check.
    func connectionState(for vendor: AIVendor) -> AIConnectionState {
        vendor == self.vendor ? connectionState : settled[vendor]?.state ?? .unchecked
    }
    func lastConnectionCheck(for vendor: AIVendor) -> Date? {
        vendor == self.vendor ? lastConnectionCheck : settled[vendor]?.checked
    }

    private func switchVendor(from previous: AIVendor) {
        guard previous != vendor else { return }
        let state = connectionState, checked = lastConnectionCheck, previousCatalog = catalog
        cancelAIConnectionCheck()
        switch state {
        case .ready, .blocked: settled[previous] = .init(state: state, checked: checked, catalog: previousCatalog)
        default: settled[previous] = nil
        }
        if let restored = settled.removeValue(forKey: vendor) {
            connectionState = restored.state; lastConnectionCheck = restored.checked; catalog = restored.catalog
        } else {
            lastConnectionCheck = nil
            if analysisEnabled { refreshAIConnection(presentOnFailure: false) }
        }
    }
    private func vendorSettingsChanged(_ changed: AIVendor, recheck: Bool = false) {
        settled[changed] = nil
        guard changed == vendor else { return }
        // A changed executable is checked right away. A changed model or effort
        // is invalidated; catalog membership cannot verify the new choice.
        if recheck { refreshAIConnection() } else { cancelAIConnectionCheck() }
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
    var aiConnectionMessage: String { AIConnectionPresentation(state: connectionState, vendor: vendor).message }

    /// One bounded check per launch or explicit retry, never a retry loop.
    @discardableResult func refreshAIConnection(presentOnFailure: Bool = false) -> Task<Void, Never>? {
        cancelAIConnectionCheck()
        connectionState = .checking
        catalog = nil
        let generation = connectionGeneration, vendor = self.vendor
        let executable = URL(fileURLWithPath: executablePath(for: vendor)), preferred = preferredModelID
        let effort = reasoningEffort, claudeEffort = self.claudeEffort
        let verifyCodex = connectionVerifier, verifyClaude = claudeVerifier
        connectionTask = Task { [weak self] in
            let verification: ConnectionVerification
            do {
                verification = vendor == .codex ? try await verifyCodex(executable, preferred, effort)
                    : try await verifyClaude(executable, claudeEffort)
            }
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
                guard let model = Self.selection(vendor: vendor, identity: identity, modelName: verification.modelName,
                          preferred: preferred, effort: vendor == .codex ? effort.rawValue : claudeEffort.rawValue) else {
                    self.connectionState = .blocked(.init(.invalidResponse, stage: .probe))
                    if presentOnFailure && self.analysisEnabled { self.showConnectionSetup = true }
                    self.connectionTask = nil; return
                }
                self.connectionState = .ready(model)
                self.hasCompletedAISetup = true
                self.defaults.set(true, forKey: "aiSetup.\(vendor.rawValue).completed")
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
        let generation = connectionGeneration, executable = URL(fileURLWithPath: executablePath(for: vendor))
        let vendor = self.vendor, codexLogin = browserLogin, claudeLogin = self.claudeLogin
        let task = Task { [weak self] in
            do {
                if vendor == .codex { try await codexLogin(executable, openBrowser) } else { try await claudeLogin(executable) }
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
        if connectionState == .unchecked || (selectedModel != nil && !aiInstalled) { refreshAIConnection() }
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

    /// Only an identity matching the requested vendor and settings becomes a selection.
    static func selection(vendor: AIVendor, identity: TextProviderIdentity, modelName: String?,
                          preferred: String, effort: String) -> AIModelSelection? {
        guard identity.provider == vendor.rawValue, identity.reasoningEffort == effort else { return nil }
        switch vendor {
        case .codex:
            guard let model = CodexModel(rawValue: identity.model), preferred.isEmpty || preferred == identity.model else { return nil }
            return .init(vendor: .codex, id: model.rawValue, displayName: model.displayName)
        case .claude:
            guard let model = ClaudeModel(rawValue: identity.model) else { return nil }
            return .init(vendor: .claude, id: model.rawValue, displayName: modelName ?? model.displayName)
        }
    }

    static func verifyClaude(executable: URL, effort: ClaudeEffort) async throws -> ConnectionVerification {
        let connection = ClaudeConnection(executable: executable, model: .sonnet, effort: effort)
        do {
            let identity = try await connection.verifyConnection()
            return .init(catalog: nil, result: .success(identity), modelName: connection.resolvedModelName)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            return .init(catalog: nil, result: .failure((error as? ProviderConnectionIssue) ?? .init(.unknown, stage: .probe)))
        }
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
         claudeVerifier: @escaping ClaudeVerifier = AppSettings.verifyClaude,
         claudeLogin: @escaping ClaudeLogin = { try await ClaudeBrowserLogin.signIn(executable: $0) },
         speechAvailabilityResolver: @escaping @Sendable (SpeechConfiguration) async -> SpeechAvailability = { await AppleSpeechEngine.availability(configuration: $0) }) {
        self.defaults = defaults
        self.speechAvailabilityResolver = speechAvailabilityResolver
        self.connectionVerifier = connectionVerifier
        self.claudeVerifier = claudeVerifier
        self.browserLogin = browserLogin
        self.claudeLogin = claudeLogin
        hasCompletedAISetup = AIVendor.allCases.contains { defaults.bool(forKey: "aiSetup.\($0.rawValue).completed") }
        if let legacy = UserDefaults(suiteName: "app.sori.mac") {
            for key in ["language", "codexPath", "ffmpegPath"] where defaults.object(forKey: key) == nil {
                if let value = legacy.object(forKey: key) { defaults.set(value, forKey: key) }
            }
        }
        let savedLanguage = defaults.string(forKey: "language") ?? "ko"
        language = savedLanguage == "auto" ? "ko" : savedLanguage
        defaults.set(savedLanguage == "auto" ? "ko" : savedLanguage, forKey: "language")
        let codex = defaults.string(forKey: "codexPath") ?? Self.find("codex")
        let claude = defaults.string(forKey: "claudePath") ?? Self.find("claude")
        codexPath = codex; claudePath = claude
        // Existing users keep Codex. A new user without Codex starts with an installed Claude.
        if let saved = defaults.string(forKey: "aiVendor").flatMap(AIVendor.init(rawValue:)) { vendor = saved }
        else { vendor = !FileManager.default.isExecutableFile(atPath: codex) && FileManager.default.isExecutableFile(atPath: claude) ? .claude : .codex }
        ffmpegPath = defaults.string(forKey: "ffmpegPath") ?? Self.find("ffmpeg")
        analysisEnabled = defaults.object(forKey: "analysisEnabled") == nil || defaults.bool(forKey: "analysisEnabled")
        preferredModelID = defaults.string(forKey: "codexPreferredModel") ?? ""
        reasoningEffort = ReasoningEffort(rawValue: defaults.string(forKey: "codexReasoningEffort") ?? "") ?? .medium
        claudeEffort = ClaudeEffort(rawValue: defaults.string(forKey: "claudeEffort") ?? "") ?? .medium
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
    /// The active vendor's CLI is installed at its configured path.
    var aiInstalled: Bool { isInstalled(vendor) }
    var analysisReady: Bool { analysisEnabled && aiInstalled && selectedModel?.vendor == vendor }
    var transcriptionConfiguration: SpeechConfiguration { .init(language: language) }

    // Compose a provider from the current vendor settings once per job. Its
    // immutable configuration keeps later UI changes out of the running job.
    func makeTextProvider() -> (any TextGenerationProvider)? {
        guard analysisEnabled, let model = selectedModel else { return nil }
        switch model.vendor {
        case .codex:
            guard let codexModel = CodexModel(rawValue: model.id) else { return nil }
            return CodexTextProvider(configuration: .init(executable: URL(fileURLWithPath: codexPath), model: codexModel,
                reasoningEffort: reasoningEffort, requestTimeout: requestTimeout))
        case .claude:
            guard let claudeModel = ClaudeModel(rawValue: model.id) else { return nil }
            return ClaudeTextProvider(configuration: .init(executable: URL(fileURLWithPath: claudePath), model: claudeModel,
                effort: claudeEffort, requestTimeout: requestTimeout))
        }
    }
}
