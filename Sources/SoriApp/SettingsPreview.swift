import Foundation
import DoongdoongCodex
import DoongdoongTranscription

/// Only offscreen settings renders receive these fixtures. No CLI, microphone,
/// model download, or personal preferences are accessed to render a state.
@MainActor enum SettingsPreview {
    static func makeSettings() -> AppSettings? {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--snapshot"), args.contains("--settings-preview") || args.contains("--providers-preview") else { return nil }
        let name = "doongdoong-settings-preview-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else { return nil }
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("ko", forKey: "language")
        defaults.set(args.contains("--providers-missing-preview") ? "/missing/codex" : "/usr/bin/true", forKey: "codexPath")
        defaults.set("/usr/bin/true", forKey: "ffmpegPath")
        defaults.set(!args.contains("--providers-disabled-preview"), forKey: "analysisEnabled")
        return AppSettings(defaults: defaults, catalogResolver: { _ in
            if args.contains("--providers-login-preview") { throw CodexModelDiscovery.DiscoveryError.loginRequired }
            if args.contains("--providers-error-preview") { throw URLError(.notConnectedToInternet) }
            return .init(models: [
                .init(model: .sol, reasoningEfforts: [.low, .medium, .high]),
                .init(model: .luna, reasoningEfforts: [.low, .medium])
            ])
        }, speechAvailabilityResolver: { _ in
            if args.contains("--speech-download-preview") { return .downloadRequired }
            if args.contains("--speech-unavailable-preview") { return .unsupportedLanguage }
            return .ready
        })
    }
}
