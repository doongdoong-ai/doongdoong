import XCTest
import SoriCore
import SoriSpeech
import DoongdoongTranscription
@testable import SoriApp

final class ModelSelectionTests: XCTestCase {
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
            let arguments = try TranscriptionPipeline.requestArguments(schema: URL(fileURLWithPath: "/tmp/schema"),
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
