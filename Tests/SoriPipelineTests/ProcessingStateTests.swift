import XCTest
import SoriCore
@testable import SoriApp

final class ProcessingStateTests: XCTestCase {
    @MainActor func testEstimateStartsWithInferenceAndSurvivesRetry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(root: root)
        let id = UUID(); store.processingID = id
        store.updateProgress(.init(stage: .correction, detail: "연결 확인"), for: id)
        XCTAssertNil(store.processingEstimateStartedUptime)
        store.updateProgress(.init(stage: .correction, detail: "교정", estimatedDuration: 120), for: id)
        XCTAssertNotNil(store.processingEstimateStartedUptime)
        let started = ProcessInfo.processInfo.systemUptime - 30
        store.processingEstimateStartedUptime = started
        store.updateProgress(.init(stage: .correction, detail: "다시 확인", estimatedDuration: 120), for: id)
        XCTAssertEqual(store.processingEstimateStartedUptime, started)
        store.updateProgress(.init(stage: .analysis, detail: "요약"), for: UUID())
        XCTAssertEqual(store.processingEstimateStartedUptime, started, "Other jobs must not affect the active clock")
        store.updateProgress(.init(stage: .analysis, detail: "요약"), for: id)
        XCTAssertNil(store.processingEstimateStartedUptime)
        XCTAssertTrue(store.processingCompletedSteps.contains(.correction))
    }

    @MainActor func testQueueUsesItsOwnWorkKindAndFailedStepStaysIncomplete() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(root: root)
        let active = UUID(); store.processingID = active; store.processingSummaryOnly = true
        var queued = Recording(projectID: UUID(), title: "대기 중")
        queued.work = .init(kind: .transcription)
        store.recordings = [queued]; store.queue = [queued.id]
        XCTAssertTrue(store.isSummaryOnly(active))
        XCTAssertFalse(store.isSummaryOnly(queued.id), "Do not borrow the active job's roadmap")
        store.recordings[0].work = .init(kind: .summary)
        XCTAssertTrue(store.isSummaryOnly(queued.id))
        XCTAssertNil(store.progress(for: queued.id))
        store.updateProgress(.init(stage: .analysis, detail: "요약 실패", issue: true), for: active)
        store.updateProgress(.init(stage: .saving, detail: "전사문만 보관"), for: active)
        XCTAssertTrue(store.processingIssues.contains(.summary))
        XCTAssertFalse(store.processingCompletedSteps.contains(.summary))
    }
}
