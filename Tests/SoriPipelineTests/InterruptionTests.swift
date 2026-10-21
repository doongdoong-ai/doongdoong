import XCTest
import SoriCore
import SoriSpeech
import DoongdoongAI
import DoongdoongTranscription
@testable import SoriApp

private actor RecoveryRecognizer: SpeechRecognizer {
    var calls = 0
    func transcribe(wave: Data, configuration: WhisperConfiguration) async throws -> [SpeechSegment] {
        calls += 1
        return [.init(start: 0, end: 1, text: "첫 번째 녹음입니다.")]
    }
}

@MainActor private final class RecoveryProvider: TextGenerationProvider {
    let identity = TextProviderIdentity(provider: "fixture", model: "fixture", reasoningEffort: "medium")
    var blocking = true
    var inputs: [String] = []
    var began: (() -> Void)?
    func checkConnection() async throws {}
    func generate(_ request: StructuredTextRequest) async throws -> Data {
        inputs.append(String(decoding: request.input, as: UTF8.self))
        if blocking { began?(); try await Task.sleep(for: .seconds(60)) }
        if request.instructions == LectureReviewPrompts.correction {
            return Data(#"{"complete":true,"edits":[]}"#.utf8)
        }
        return Data(#"{"title":"보존한 강의","synopsis":"저장한 내용을 확인합니다.","highlights":[]}"#.utf8)
    }
}

final class InterruptionTests: XCTestCase {
    @MainActor private func settings(_ root: URL) throws -> AppSettings {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: root.lastPathComponent))
        defaults.set("/usr/bin/true", forKey: "codexPath")
        defaults.set("/usr/bin/true", forKey: "whisperPath")
        defaults.set("/usr/bin/true", forKey: "whisperModel")
        defaults.set("/usr/bin/true", forKey: "vadModel")
        return AppSettings(defaults: defaults, modelResolver: { _ in .sol })
    }
    private func wave(finalized: Bool) -> Data {
        var data = Data("RIFF".utf8)
        func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        u32(finalized ? 64036 : 36); data.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(16000); u32(32000); u16(2); u16(16); data.append(Data("data".utf8)); u32(finalized ? 64000 : 0)
        for index in 0..<32000 { u16(UInt16(bitPattern: Int16(sin(Double(index) * 0.1) * 10000))) }
        return data
    }
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("recovery-test-" + UUID().uuidString) }
    private func cleanup(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removePersistentDomain(forName: root.lastPathComponent)
    }

    @MainActor func testCrashRecoveryWithoutFirstASRPollRepairsPlaybackAndPreservesOriginal() async throws {
        let root = root(); defer { cleanup(root) }
        let repo = try LibraryRepository(root: root), project = try repo.createProject(name: "강의")
        var recording = try repo.createRecording(project: project, title: "중단된 녹음")
        recording.status = .recording; recording.notes = "중요한 메모"
        // Legacy recording: no work intent or ASR marker was written before the crash.
        try repo.save(recording)
        let original = wave(finalized: false), audio = try repo.audioURL(for: recording)
        try original.write(to: audio)
        let store = AppStore(root: root, settings: try settings(root))
        XCTAssertEqual(store.selectedID, recording.id)
        await store.recoverRecordings()
        let restored = try XCTUnwrap(store.selected)
        XCTAssertEqual(restored.audioFileName, "audio-local-recovered.wav")
        XCTAssertEqual(restored.duration, 2, accuracy: 0.01)
        XCTAssertEqual(restored.notes, recording.notes)
        XCTAssertEqual(restored.work?.kind, .recording)
        XCTAssertEqual(try Data(contentsOf: audio), original)
        XCTAssertEqual(store.audio.duration, 2, accuracy: 0.01)
        XCTAssertFalse(store.audio.isRecording)
        XCTAssertNil(store.processingID)
        let relaunched = AppStore(root: root, settings: try settings(root))
        XCTAssertEqual(relaunched.selected?.audioFileName, restored.audioFileName)
        XCTAssertEqual(relaunched.audio.duration, 2, accuracy: 0.01)
    }

    @MainActor func testSleepWakeResumesQueueAndSummaryIntentWithoutRepeatingASR() async throws {
        let root = root(); defer { cleanup(root) }
        let repo = try LibraryRepository(root: root), project = try repo.createProject(name: "강의")
        let first = try repo.createRecording(project: project, title: "첫 번째")
        var second = try repo.createRecording(project: project, title: "두 번째")
        second.status = .ready; second.notes = "사용자가 작성한 메모"
        second.segments = [.init(id: 8, start: 0, end: 1, text: "사용자가 직접 고친 두 번째 문장입니다.")]
        try repo.save(second)
        for item in [first, second] { try wave(finalized: true).write(to: repo.audioURL(for: item)) }
        let settings = try settings(root); await settings.refreshAIConnection()?.value
        let provider = RecoveryProvider(), recognizer = RecoveryRecognizer()
        let began = expectation(description: "correction began")
        provider.began = { began.fulfill() }
        let store = AppStore(root: root, settings: settings, recognizer: recognizer, textProvider: provider)
        store.enqueue(first.id); store.enqueue(second.id, lectureOnly: true)
        await fulfillment(of: [began], timeout: 5)
        XCTAssertTrue(store.recordings.first(where: { $0.id == first.id })?.segments.isEmpty == true)
        XCTAssertTrue(try repo.load().recordings.first(where: { $0.id == first.id })?.segments.isEmpty == true,
                      "Unreviewed words must not leak to the library, copy, search or export")
        store.systemWillSleep(); store.systemWillSleep()
        XCTAssertTrue(store.isSleeping)
        XCTAssertEqual(store.recordings.first(where: { $0.id == second.id })?.work?.kind, .summary)
        XCTAssertEqual(store.recordings.first(where: { $0.id == second.id })?.work?.cause, .sleep)
        provider.blocking = false
        // Wake followed immediately by another sleep must not start a stale generation.
        let staleWake = store.systemDidWake()
        store.systemWillSleep()
        await staleWake.value
        await store.systemDidWake().value
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while store.processingID != nil || !store.queue.isEmpty {
            guard ContinuousClock.now < deadline else { return XCTFail("Queue did not finish") }
            try await Task.sleep(for: .milliseconds(20))
        }
        let calls = await recognizer.calls
        XCTAssertEqual(calls, 1, "Committed audio must be reused; summary-only work must not run ASR")
        XCTAssertEqual(store.recordings.first(where: { $0.id == second.id })?.segments, second.segments)
        XCTAssertEqual(store.recordings.first(where: { $0.id == second.id })?.notes, second.notes)
        XCTAssertTrue(provider.inputs.last?.contains("사용자가 직접 고친 두 번째 문장") == true)
        XCTAssertTrue(store.recordings.allSatisfy { $0.work == nil && $0.status == .ready })
        XCTAssertFalse(store.audio.isRecording)
        let disk = try repo.load().recordings
        XCTAssertTrue(disk.allSatisfy { $0.work == nil })
    }

    @MainActor func testFailedRecoveryLeavesOriginalAndRetryIntentVisible() async throws {
        let root = root(); defer { cleanup(root) }
        let repo = try LibraryRepository(root: root), project = try repo.createProject(name: "강의")
        var item = try repo.createRecording(project: project, title: "손상 파일")
        item.status = .recording; try repo.save(item)
        let audio = try repo.audioURL(for: item), bytes = Data("incomplete header".utf8)
        try bytes.write(to: audio)
        let store = AppStore(root: root, settings: try settings(root))
        await store.recoverRecordings()
        XCTAssertEqual(try Data(contentsOf: audio), bytes)
        XCTAssertNotNil(store.selected?.message)
        XCTAssertEqual(store.selected?.work?.state, .interrupted)
        XCTAssertEqual(store.recordings.count, 1)
        XCTAssertFalse(store.canResumeWork(item.id))
    }

    @MainActor func testUserCancelledSleepWorkDoesNotRestartOnWakeOrRelaunch() async throws {
        let root = root(); defer { cleanup(root) }
        let repo = try LibraryRepository(root: root), project = try repo.createProject(name: "강의")
        let item = try repo.createRecording(project: project, title: "중단")
        try wave(finalized: true).write(to: repo.audioURL(for: item))
        let settings = try settings(root); await settings.refreshAIConnection()?.value
        let provider = RecoveryProvider(), began = expectation(description: "review requested")
        provider.began = { began.fulfill() }
        let store = AppStore(root: root, settings: settings, recognizer: RecoveryRecognizer(), textProvider: provider)
        store.enqueue(item.id)
        await fulfillment(of: [began], timeout: 5)
        store.systemWillSleep(); store.cancelProcessing(item.id)
        let stale = store.systemDidWake(); store.systemWillSleep()
        await stale.value; await store.systemDidWake().value
        XCTAssertNil(store.processingID); XCTAssertTrue(store.queue.isEmpty)
        XCTAssertEqual(store.recordings.first?.work?.cause, .userStopped)
        XCTAssertTrue(store.recordings.first?.segments.isEmpty == true)
        let saved = await store.prepareForTermination(); XCTAssertTrue(saved)
        let relaunched = AppStore(root: root, settings: settings)
        XCTAssertNil(relaunched.processingID); XCTAssertTrue(relaunched.queue.isEmpty)
        XCTAssertEqual(relaunched.recordings.first?.work?.cause, .userStopped)
        XCTAssertFalse(relaunched.audio.isRecording)
    }
}
