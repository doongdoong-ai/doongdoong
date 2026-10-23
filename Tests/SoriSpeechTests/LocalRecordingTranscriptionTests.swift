import XCTest
import DoongdoongTranscription
@testable import SoriSpeech

private actor ScheduledRecognizer: SpeechRecognizer {
    private(set) var calls = 0
    private(set) var preparations = 0
    private(set) var cancelled = false
    let failingCall: Int?
    let firstCallStarted: (@Sendable () -> Void)?
    private var released = false

    init(failingCall: Int? = nil, firstCallStarted: (@Sendable () -> Void)? = nil) {
        self.failingCall = failingCall; self.firstCallStarted = firstCallStarted
    }
    func prepare(configuration: SpeechConfiguration, onProgress: (@Sendable (SpeechPreparation) async -> Void)?) async throws {
        preparations += 1
    }
    func release() { released = true }
    func transcribe(wave: Data, configuration: SpeechConfiguration) async throws -> [SpeechSegment] {
        calls += 1
        if calls == failingCall { throw TranscriptionError.timedOut }
        if calls == 1, let firstCallStarted {
            firstCallStarted()
            do {
                while !released { try await Task.sleep(for: .milliseconds(10)) }
            } catch { cancelled = true; throw error }
        }
        return [.init(start: 0, end: 1, text: "저장된 강의 구간입니다.")]
    }
}

/// Grow a real PCM file without a microphone or 25 minutes of wall-clock waiting.
private struct ScheduledRecording {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("scheduled-asr-" + UUID().uuidString)
    var audio: URL { root.appendingPathComponent("audio.wav") }
    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try RecordingPCM.waveHeader(bytes: 0).write(to: audio)
    }
    func grow(to seconds: Int, closed: Bool = false) throws {
        let file = try FileHandle(forWritingTo: audio); defer { try? file.close() }
        var bytes = Int(try file.seekToEnd()) - 44
        let end = seconds * 32_000
        // Nonzero samples keep the core's quiet-boundary heuristic deterministic.
        let block = Data(repeating: 63, count: 32_000)
        while bytes < end { try file.write(contentsOf: block); bytes += block.count }
        if closed {
            try file.seek(toOffset: 0)
            try file.write(contentsOf: RecordingPCM.waveHeader(bytes: bytes))
        }
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

@MainActor final class LocalRecordingTranscriptionTests: XCTestCase {
    func testOnlySaved25MinuteBoundariesStartASRAndFinalTailReusesCheckpoints() async throws {
        let file = try ScheduledRecording(); defer { file.remove() }
        let recognizer = ScheduledRecognizer()
        let live = LocalRecordingTranscription(audio: file.audio, directory: file.root, configuration: .init(), recognizer: recognizer)
        try file.grow(to: 25 * 60 - 1)
        try await live.processScheduledBatch()
        // Repeated checks with no file growth represent paused recording.
        try await live.processScheduledBatch()
        var calls = await recognizer.calls, preparations = await recognizer.preparations
        XCTAssertEqual(calls, 0); XCTAssertEqual(preparations, 0)
        try file.grow(to: 25 * 60)
        try await live.processScheduledBatch()
        calls = await recognizer.calls
        XCTAssertEqual(calls, 25)
        try file.grow(to: 50 * 60 - 1)
        try await live.processScheduledBatch()
        calls = await recognizer.calls
        XCTAssertEqual(calls, 25, "New audio below the next 25-minute boundary stays pending")
        try file.grow(to: 50 * 60)
        try await live.processScheduledBatch()
        calls = await recognizer.calls
        XCTAssertEqual(calls, 50)
        await live.finish()
        try file.grow(to: 50 * 60 + 3, closed: true)
        let result = try await LocalTranscription.transcribe(audio: file.audio, directory: file.root,
            configuration: .init(), recognizer: recognizer)
        calls = await recognizer.calls
        XCTAssertEqual(calls, 51, "Finalization must decode only the three-second tail")
        XCTAssertEqual(result.count, 51)
        XCTAssertEqual(result.last?.start, 3000)
    }

    func testShortRecordingStopsIdleWorkerAndTranscribesImmediatelyAfterClosing() async throws {
        let file = try ScheduledRecording(); defer { file.remove() }
        let recognizer = ScheduledRecognizer()
        try file.grow(to: 90)
        let live = LocalRecordingTranscription(audio: file.audio, directory: file.root, configuration: .init(), recognizer: recognizer)
        live.start()
        await Task.yield()
        let stopped = expectation(description: "Idle polling stops without waiting for a recording boundary")
        Task { await live.finish(); stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 5)
        let before = await recognizer.calls
        XCTAssertEqual(before, 0)
        try file.grow(to: 90, closed: true)
        let result = try await LocalTranscription.transcribe(audio: file.audio, directory: file.root,
            configuration: .init(), recognizer: recognizer)
        let calls = await recognizer.calls
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(result.map(\.start), [0, 60])
    }

    func testFailedBatchCanRetryBeforeNextBoundaryAndResumeNeverRepeatsCommittedAudio() async throws {
        let file = try ScheduledRecording(); defer { file.remove() }
        let recognizer = ScheduledRecognizer(failingCall: 2)
        try file.grow(to: 25 * 60)
        let live = LocalRecordingTranscription(audio: file.audio, directory: file.root, configuration: .init(), recognizer: recognizer)
        do { try await live.processScheduledBatch(); XCTFail("Expected failure in the second chunk") }
        catch { XCTAssertTrue(error is TranscriptionError) }
        try await live.processScheduledBatch()
        var calls = await recognizer.calls
        XCTAssertEqual(calls, 26, "Retry reuses the first chunk and completes this batch now")
        await live.finish(cancel: true)
        let resumed = LocalRecordingTranscription(audio: file.audio, directory: file.root, configuration: .init(), recognizer: recognizer)
        try await resumed.processScheduledBatch()
        calls = await recognizer.calls
        XCTAssertEqual(calls, 26, "A new session validates and reuses completed checkpoints")
        try file.grow(to: 26 * 60)
        try await resumed.processScheduledBatch()
        calls = await recognizer.calls
        XCTAssertEqual(calls, 26, "The resumed session waits for the next boundary after catching up")
        await resumed.finish()
    }

    func testNormalStopDrainsActiveBatchButSleepCancelsItAndResumeFinishes() async throws {
        for cancel in [false, true] {
            let file = try ScheduledRecording(); defer { file.remove() }
            try file.grow(to: 25 * 60)
            let began = expectation(description: "Recognition started")
            let recognizer = ScheduledRecognizer(firstCallStarted: { began.fulfill() })
            let live = LocalRecordingTranscription(audio: file.audio, directory: file.root, configuration: .init(), recognizer: recognizer)
            live.start()
            await fulfillment(of: [began], timeout: 5)
            let stopped = expectation(description: "Recording worker finished")
            Task { await live.finish(cancel: cancel); stopped.fulfill() }
            if !cancel {
                await Task.yield()
                await recognizer.release()
            }
            await fulfillment(of: [stopped], timeout: 10)
            let wasCancelled = await recognizer.cancelled
            XCTAssertEqual(wasCancelled, cancel)
            var calls = await recognizer.calls
            XCTAssertEqual(calls, cancel ? 1 : 25)
            try file.grow(to: 25 * 60, closed: true)
            let result = try await LocalTranscription.transcribe(audio: file.audio, directory: file.root,
                configuration: .init(), recognizer: recognizer)
            calls = await recognizer.calls
            XCTAssertEqual(calls, cancel ? 26 : 25)
            XCTAssertEqual(result.count, 25)
        }
    }
}
