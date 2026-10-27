import XCTest
import DoongdoongAI
import DoongdoongCodex
import SoriCore
@testable import SoriApp

final class ConnectionSetupTests: XCTestCase {
    @MainActor private func fixture(_ verifier: @escaping AppSettings.ConnectionVerifier,
        login: @escaping AppSettings.BrowserLogin = { _, _ in }) throws -> (URL, UserDefaults, AppSettings) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("connection-\(UUID().uuidString)")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: root.lastPathComponent))
        defaults.set("/usr/bin/true", forKey: "codexPath")
        return (root, defaults, AppSettings(defaults: defaults, connectionVerifier: verifier, browserLogin: login))
    }
    private func cleanup(_ root: URL, _ defaults: UserDefaults) {
        defaults.removePersistentDomain(forName: root.lastPathComponent)
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor func testFirstFailureDoesNotStartRecordingOrCompleteSetup() async throws {
        var calls = 0
        let (root, defaults, settings) = try fixture { _, _, _ in
            calls += 1; throw ProviderConnectionIssue(.unknown, stage: .probe)
        }
        defer { cleanup(root, defaults) }
        let store = AppStore(root: root, settings: settings)
        await settings.refreshAIConnection(presentOnFailure: true)?.value
        XCTAssertTrue(settings.showConnectionSetup); XCTAssertFalse(settings.hasCompletedAISetup)
        XCTAssertTrue(settings.analysisEnabled)
        XCTAssertFalse(defaults.bool(forKey: "aiSetup.codex.completed"))
        XCTAssertFalse(store.showRecordingDestination)
        store.requestRecording()
        XCTAssertTrue(settings.showConnectionSetup)
        XCTAssertFalse(store.showRecordingDestination)
        store.requestRecording()
        XCTAssertTrue(settings.showConnectionSetup)
        XCTAssertFalse(store.showRecordingDestination)
        XCTAssertEqual(calls, 1, "Unknown failures must not trigger a retry loop")
    }

    @MainActor func testSuccessfulRetryContinuesRequestedLecture() async throws {
        var succeeds = false
        let (root, defaults, settings) = try fixture { _, _, effort in
            if !succeeds { throw ProviderConnectionIssue(.network, stage: .account) }
            return ConnectionFixture.ready(.sol, effort: effort)
        }
        defer { cleanup(root, defaults) }
        let store = AppStore(root: root, settings: settings)
        await settings.refreshAIConnection()?.value
        store.requestRecording()
        XCTAssertTrue(settings.showConnectionSetup)
        succeeds = true
        await settings.refreshAIConnection()?.value
        XCTAssertTrue(settings.hasCompletedAISetup); XCTAssertTrue(settings.showConnectionSetup)
        store.finishConnectionSetup(); store.connectionSetupDismissed()
        XCTAssertFalse(settings.showConnectionSetup)
        XCTAssertTrue(store.showRecordingDestination)
    }

    @MainActor func testSavedRecordingRemainsUntouchedUntilConnected() async throws {
        let (root, defaults, settings) = try fixture { _, _, _ in throw ProviderConnectionIssue(.unknown, stage: .probe) }
        defer { cleanup(root, defaults) }
        let store = AppStore(root: root, settings: settings)
        let repository = try XCTUnwrap(store.repository), project = try XCTUnwrap(store.projects.first)
        var recording = try repository.createRecording(project: project, title: "저장된 녹음")
        recording.recordingMode = .audioOnly; recording.status = .saved; recording.duration = 60
        try repository.save(recording); store.recordings = [recording]
        await settings.refreshAIConnection()?.value
        store.enqueue(recording.id)
        XCTAssertTrue(settings.showConnectionSetup); XCTAssertNil(store.processingID); XCTAssertTrue(store.queue.isEmpty)
        XCTAssertEqual(store.recordings.first?.status, .saved)
        XCTAssertTrue(store.canModify(recording.id))
        await settings.refreshAIConnection()?.value
        XCTAssertTrue(settings.showConnectionSetup); XCTAssertFalse(settings.hasCompletedAISetup)
        XCTAssertNil(store.processingID); XCTAssertTrue(store.queue.isEmpty)
        XCTAssertEqual(store.recordings.first?.status, .saved)
    }

    @MainActor func testUnstartedBatchRemainsSavedDuringFailedConnectionRetry() async throws {
        let (root, defaults, settings) = try fixture { _, _, _ in throw ProviderConnectionIssue(.unknown, stage: .probe) }
        defer { cleanup(root, defaults) }
        let store = AppStore(root: root, settings: settings)
        let repository = try XCTUnwrap(store.repository), project = try XCTUnwrap(store.projects.first)
        let first = try repository.createRecording(project: project, title: "첫 파일")
        var second = try repository.createRecording(project: project, title: "두 번째 파일")
        second.work = .init(kind: .transcription)
        store.recordings = [first, second]
        await settings.refreshAIConnection()?.value
        store.enqueue(first.id); store.enqueue(second.id)
        XCTAssertTrue(settings.showConnectionSetup)
        XCTAssertEqual(store.recordings.map(\.status), [.saved, .saved])
        XCTAssertTrue(store.recordings.allSatisfy { $0.work == nil })
        await settings.refreshAIConnection()?.value
        XCTAssertTrue(settings.showConnectionSetup)
        XCTAssertTrue(store.queue.isEmpty); XCTAssertNil(store.processingID)
        XCTAssertEqual(store.recordings.map(\.status), [.saved, .saved])
    }

    @MainActor func testSetupCompletionPersistsButCurrentReadinessDoesNot() async throws {
        let (root, defaults, settings) = try fixture { _, _, effort in ConnectionFixture.ready(.sol, effort: effort) }
        defer { cleanup(root, defaults) }
        await settings.refreshAIConnection(presentOnFailure: true)?.value
        XCTAssertTrue(settings.hasCompletedAISetup); XCTAssertFalse(settings.showConnectionSetup)
        let next = AppSettings(defaults: defaults, connectionVerifier: { _, _, _ in throw ProviderConnectionIssue(.network, stage: .account) })
        XCTAssertTrue(next.hasCompletedAISetup); XCTAssertNil(next.selectedModel)
        await next.refreshAIConnection(presentOnFailure: !next.hasCompletedAISetup)?.value
        XCTAssertFalse(next.showConnectionSetup); XCTAssertFalse(next.analysisReady)
        XCTAssertTrue(next.hasCompletedAISetup)
    }

    @MainActor func testLoginCallbackStillRequiresProbe() async throws {
        var logins = 0, probes = 0
        let (root, defaults, settings) = try fixture({ _, _, _ in
            probes += 1
            throw ProviderConnectionIssue(.usageLimited, stage: .probe, retry: .later)
        }, login: { _, _ in logins += 1 })
        defer { cleanup(root, defaults) }
        await settings.signIn { _ in true }.value
        XCTAssertEqual(logins, 1); XCTAssertEqual(probes, 1)
        XCTAssertEqual(settings.connectionIssue?.kind, .usageLimited)
        XCTAssertFalse(settings.hasCompletedAISetup); XCTAssertFalse(settings.checkingAI)
    }

    @MainActor func testDisablingAnalysisDoesNotTrapSuccessfulSetupOrReopenFailure() async throws {
        let (root, defaults, settings) = try fixture { _, _, effort in ConnectionFixture.ready(.sol, effort: effort) }
        defer { cleanup(root, defaults) }
        let store = AppStore(root: root, settings: settings)
        await settings.refreshAIConnection()?.value
        settings.showConnectionSetup = true; settings.analysisEnabled = false
        store.finishConnectionSetup(); store.connectionSetupDismissed()
        XCTAssertFalse(settings.showConnectionSetup)
        let offline = AppSettings(defaults: defaults, connectionVerifier: { _, _, _ in
            throw ProviderConnectionIssue(.unknown, stage: .probe)
        })
        await offline.refreshAIConnection(presentOnFailure: true)?.value
        XCTAssertFalse(offline.showConnectionSetup)
    }

    @MainActor func testDismissalCancelsProbeAndIgnoresLateFailure() async throws {
        var pending: CheckedContinuation<AppSettings.ConnectionVerification, Error>?
        let started = expectation(description: "probe started")
        let (root, defaults, settings) = try fixture { _, _, _ in
            try await withCheckedThrowingContinuation { pending = $0; started.fulfill() }
        }
        defer { cleanup(root, defaults) }
        let task = settings.refreshAIConnection(presentOnFailure: true)
        await fulfillment(of: [started], timeout: 2)
        settings.showConnectionSetup = true
        settings.dismissConnectionSetup()
        pending?.resume(throwing: ProviderConnectionIssue(.unknown, stage: .probe))
        await task?.value
        XCTAssertEqual(settings.connectionState, .unchecked)
        XCTAssertFalse(settings.showConnectionSetup); XCTAssertFalse(settings.hasCompletedAISetup)
    }

    @MainActor func testCancelledProviderCannotLeaveCheckingState() async throws {
        let (root, defaults, settings) = try fixture { _, _, _ in throw CancellationError() }
        defer { cleanup(root, defaults) }
        await settings.refreshAIConnection(presentOnFailure: true)?.value
        XCTAssertEqual(settings.connectionState, .unchecked)
        XCTAssertFalse(settings.showConnectionSetup)
    }

    @MainActor func testEveryFailureHasAnActionAndUnknownDoesNotPretendLoginRequired() {
        for kind in ProviderConnectionIssue.Kind.allCases {
            let view = AIConnectionPresentation(state: .blocked(.init(kind, stage: .probe)))
            XCTAssertFalse(view.title.isEmpty); XCTAssertFalse(view.message.isEmpty); XCTAssertFalse(view.actionTitle.isEmpty)
            if [.unknown, .network, .serviceUnavailable, .usageLimited].contains(kind) { XCTAssertEqual(view.action, .retry) }
        }
    }
}
