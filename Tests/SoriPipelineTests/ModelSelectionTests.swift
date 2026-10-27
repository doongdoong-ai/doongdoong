import XCTest
import SoriCore
import SoriSpeech
import DoongdoongTranscription
import DoongdoongAI
@testable import SoriApp

final class ModelSelectionTests: XCTestCase {
    @MainActor func testVendorSettingsPersistButRunningJobKeepsItsSnapshot() async throws {
        let name = "doongdoong-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("/usr/bin/true", forKey: "codexPath")
        let settings = AppSettings(defaults: defaults, connectionVerifier: { _, preferred, effort in
            let catalog = CodexCatalog(models: [.init(model: .sol, reasoningEfforts: [.medium, .high]), .init(model: .luna, reasoningEfforts: [.medium])])
            let model = try catalog.select(preferred: CodexModel(rawValue: preferred), effort: effort)
            return ConnectionFixture.ready(model, effort: effort, catalog: catalog)
        })
        await settings.refreshAIConnection()?.value
        settings.reasoningEffort = .high
        await settings.refreshAIConnection()?.value
        settings.requestTimeout = 600
        let job = try XCTUnwrap(settings.makeTextProvider() as? CodexTextProvider).configuration
        settings.preferredModelID = CodexModel.luna.rawValue
        XCTAssertNil(settings.selectedModel, "Unsupported effort must not silently fall back")
        settings.reasoningEffort = .medium
        await settings.refreshAIConnection()?.value
        XCTAssertEqual(settings.selectedModel, .luna)
        settings.analysisEnabled = false
        XCTAssertNil(settings.makeTextProvider())
        XCTAssertEqual(job.model, .sol)
        XCTAssertEqual(job.reasoningEffort, .high)
        XCTAssertEqual(job.requestTimeout, 600)
        let restored = AppSettings(defaults: defaults)
        XCTAssertEqual(restored.preferredModelID, CodexModel.luna.rawValue)
        XCTAssertEqual(restored.reasoningEffort, .medium)
        XCTAssertEqual(restored.requestTimeout, 600)
        XCTAssertFalse(restored.analysisEnabled)
        XCTAssertNil(restored.selectedModel, "Each launch must check the catalog again")
    }
    @MainActor func testEachSessionResolvesAgainAndDoesNotKeepStaleSelection() async throws {
        let name = "doongdoong-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("/usr/bin/true", forKey: "codexPath")
        var calls = 0
        let first = AppSettings(defaults: defaults, connectionVerifier: { _, _, effort in calls += 1; return ConnectionFixture.ready(.sol, effort: effort) })
        XCTAssertNil(first.selectedModel)
        XCTAssertNil(first.makeTextProvider(), "An unverified model must not create a provider")
        await first.refreshAIConnection()?.value
        XCTAssertEqual(first.selectedModel, .sol)
        let next = AppSettings(defaults: defaults, connectionVerifier: { _, _, effort in calls += 1; return ConnectionFixture.ready(.luna, effort: effort) })
        XCTAssertNil(next.selectedModel)
        await next.refreshAIConnection()?.value
        XCTAssertEqual(next.selectedModel, .luna)
        XCTAssertEqual(calls, 2)
        let offline = AppSettings(defaults: defaults, connectionVerifier: { _, _, _ in throw ProviderConnectionIssue(.network, stage: .account, retry: .manual) })
        await offline.refreshAIConnection()?.value
        XCTAssertNil(offline.selectedModel)
        XCTAssertFalse(offline.analysisReady)
        XCTAssertEqual(offline.connectionIssue?.kind, .network)
    }

    @MainActor func testLateCancelledLookupCannotOverwriteNewerSelection() async throws {
        let name = "doongdoong-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("/usr/bin/true", forKey: "codexPath")
        var pending: CheckedContinuation<CodexModel, Never>?
        let started = expectation(description: "first lookup suspended")
        var calls = 0
        let settings = AppSettings(defaults: defaults, connectionVerifier: { _, _, effort in
            calls += 1
            if calls == 1 {
                let model = await withCheckedContinuation { continuation in pending = continuation; started.fulfill() }
                return ConnectionFixture.ready(model, effort: effort)
            }
            return ConnectionFixture.ready(.luna, effort: effort)
        })
        let old = settings.refreshAIConnection()
        await fulfillment(of: [started], timeout: 2)
        await settings.refreshAIConnection()?.value
        pending?.resume(returning: .sol)
        await old?.value
        XCTAssertEqual(settings.selectedModel, .luna)
        XCTAssertEqual(settings.makeTextProvider()?.identity.model, CodexModel.luna.rawValue)
    }

    @MainActor func testCLIRequestsUseChosenModelMediumAndExplicitProvider() throws {
        for model in CodexModel.allCases {
            let arguments = try CodexTextProvider.requestArguments(schema: URL(fileURLWithPath: "/tmp/schema"),
                response: URL(fileURLWithPath: "/tmp/output"), instructions: "Review only.", selection: model)
            let index = try XCTUnwrap(arguments.firstIndex(of: "--model"))
            XCTAssertEqual(arguments[index + 1], model.rawValue)
            XCTAssertTrue(arguments.contains("model_reasoning_effort=\"medium\""))
            XCTAssertTrue(arguments.contains("model_provider=\"openai\""))
            XCTAssertTrue(arguments.contains("--ignore-user-config"))
        }
    }
    @MainActor func testLocalTranscriptionDoesNotRequireCodexOrLogin() throws {
        let name = "doongdoong-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("/missing-codex", forKey: "codexPath")
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.transcriptionReady)
        XCTAssertFalse(settings.analysisReady)
        XCTAssertNil(settings.selectedModel)
    }

    @MainActor func testLegacyAutomaticLanguageMigratesToKoreanWithoutModelPaths() throws {
        let name = "doongdoong-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("auto", forKey: "language")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.language, "ko")
        XCTAssertEqual(defaults.string(forKey: "language"), "ko")
        XCTAssertEqual(settings.transcriptionConfiguration.localeIdentifier, "ko-KR")
        XCTAssertTrue(settings.transcriptionReady, "Unknown/downloadable assets must not prevent recording")
    }

}

@MainActor enum ConnectionFixture {
    static func ready(_ model: CodexModel = .sol, effort: ReasoningEffort = .medium, catalog: CodexCatalog? = nil) -> AppSettings.ConnectionVerification {
        .init(catalog: catalog ?? .init(models: [.init(model: model, reasoningEfforts: [effort])]),
              result: .success(.init(provider: "codex", model: model.rawValue, reasoningEffort: effort.rawValue)))
    }
}
