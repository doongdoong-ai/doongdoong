import XCTest
import SoriCore
import SoriSpeech
import DoongdoongTranscription
@testable import SoriApp

final class ModelSelectionTests: XCTestCase {
    @MainActor func testVendorSettingsPersistButRunningJobKeepsItsSnapshot() async throws {
        let name = "doongdoong-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("/usr/bin/true", forKey: "codexPath")
        let settings = AppSettings(defaults: defaults, catalogResolver: { _ in
            .init(models: [.init(model: .sol, reasoningEfforts: [.medium, .high]), .init(model: .luna, reasoningEfforts: [.medium])])
        })
        await settings.refreshAIConnection()?.value
        settings.reasoningEffort = .high
        settings.requestTimeout = 600
        let job = settings.snapshot
        settings.preferredModelID = CodexModel.luna.rawValue
        XCTAssertNil(settings.selectedModel, "Unsupported effort must not silently fall back")
        settings.reasoningEffort = .medium
        XCTAssertEqual(settings.selectedModel, .luna)
        settings.analysisEnabled = false
        XCTAssertNil(settings.snapshot.aiModel)
        XCTAssertEqual(job.aiModel, .sol)
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
        let first = AppSettings(defaults: defaults, modelResolver: { _ in calls += 1; return .sol })
        XCTAssertNil(first.selectedModel)
        await first.refreshAIConnection()?.value
        XCTAssertEqual(first.selectedModel, .sol)
        let next = AppSettings(defaults: defaults, modelResolver: { _ in calls += 1; return .luna })
        XCTAssertNil(next.selectedModel)
        await next.refreshAIConnection()?.value
        XCTAssertEqual(next.selectedModel, .luna)
        XCTAssertEqual(calls, 2)
        let offline = AppSettings(defaults: defaults, modelResolver: { _ in throw URLError(.notConnectedToInternet) })
        await offline.refreshAIConnection()?.value
        XCTAssertNil(offline.selectedModel)
        XCTAssertFalse(offline.analysisReady)
        XCTAssertEqual(offline.connectionState, .failed)
    }

    @MainActor func testLateCancelledLookupCannotOverwriteNewerSelection() async throws {
        let name = "doongdoong-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("/usr/bin/true", forKey: "codexPath")
        var pending: CheckedContinuation<CodexModel, Never>?
        let started = expectation(description: "first lookup suspended")
        var calls = 0
        let settings = AppSettings(defaults: defaults, modelResolver: { _ in
            calls += 1
            if calls == 1 {
                return await withCheckedContinuation { continuation in pending = continuation; started.fulfill() }
            }
            return .luna
        })
        let old = settings.refreshAIConnection()
        await fulfillment(of: [started], timeout: 2)
        await settings.refreshAIConnection()?.value
        pending?.resume(returning: .sol)
        await old?.value
        XCTAssertEqual(settings.selectedModel, .luna)
        XCTAssertEqual(settings.snapshot.aiModel, .luna)
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
        let settings = PipelineSettings(codex: "/usr/bin/true", ffmpeg: "", language: "ko", transcription: .init(executable: URL(fileURLWithPath: "/usr/bin/true"), model: URL(fileURLWithPath: "/tmp/model"), vadModel: URL(fileURLWithPath: "/tmp/vad")))
        XCTAssertThrowsError(try settings.requireModel())
    }
    @MainActor func testLocalTranscriptionDoesNotRequireCodexOrLogin() throws {
        let name = "doongdoong-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("/missing-codex", forKey: "codexPath")
        defaults.set("/usr/bin/true", forKey: "whisperPath")
        defaults.set("/usr/bin/true", forKey: "whisperModel")
        defaults.set("/usr/bin/true", forKey: "vadModel")
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.transcriptionReady)
        XCTAssertFalse(settings.analysisReady)
        XCTAssertNil(settings.selectedModel)
    }

}
