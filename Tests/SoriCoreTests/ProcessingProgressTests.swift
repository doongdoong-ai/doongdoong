import XCTest
@testable import SoriCore

final class ProcessingProgressTests: XCTestCase {
    func testUnmeasuredAndInvalidWorkNeverProducesAPercentage() {
        XCTAssertNil(ProcessingProgress(stage: .analysis, detail: "").fraction)
        for total in [0, -1, Double.nan, .infinity] {
            let progress = ProcessingProgress(stage: .transcription, detail: "", completed: 5, total: total)
            XCTAssertNil(progress.fraction); XCTAssertNil(progress.countLabel)
        }
    }
    func testMeasuredProgressIsBoundedAndSafeToDisplay() {
        XCTAssertEqual(ProcessingProgress(stage: .correction, detail: "", completed: -1, total: 10).fraction, 0)
        XCTAssertEqual(ProcessingProgress(stage: .correction, detail: "", completed: 11, total: 10).fraction, 1)
        XCTAssertEqual(ProcessingProgress(stage: .transcription, detail: "", completed: 60, total: 120, unit: .audio).countLabel, "01:00 / 02:00 인식")
        XCTAssertNotNil(ProcessingProgress(stage: .transcription, detail: "", completed: .greatestFiniteMagnitude, total: .greatestFiniteMagnitude, unit: .audio).countLabel)
    }

    func testEstimateNeverClaimsCompletionAndExplainsOverrun() throws {
        let value = ProcessingProgress(stage: .correction, detail: "", estimatedDuration: 120)
        let first = value.indicator(elapsed: 60), late = value.indicator(elapsed: 240)
        XCTAssertTrue(first.isEstimated)
        XCTAssertFalse(first.isTakingLonger)
        XCTAssertTrue(late.isTakingLonger)
        XCTAssertLessThan(try XCTUnwrap(late.fraction), 1)
        XCTAssertGreaterThan(try XCTUnwrap(late.fraction), try XCTUnwrap(first.fraction))
        let validated = ProcessingProgress(stage: .correction, detail: "", completed: 20, total: 20,
                                           unit: .sentences, estimatedDuration: 120).indicator(elapsed: 60)
        XCTAssertEqual(validated.fraction, 1)
        XCTAssertFalse(validated.isEstimated)
    }

    func testUnknownWorkAndFailuresDoNotShowFalsePercentages() {
        XCTAssertNil(ProcessingProgress(stage: .analysis, detail: "").indicator(elapsed: 600).fraction)
        let failed = ProcessingProgress(stage: .correction, detail: "", completed: 1, total: 1,
                                        issue: true, estimatedDuration: 120).indicator(elapsed: 600)
        XCTAssertNil(failed.fraction)
        XCTAssertFalse(failed.isEstimated)
        for duration in [Double.nan, .infinity, -1, 0] {
            XCTAssertNil(ProcessingProgress(stage: .correction, detail: "", estimatedDuration: duration).indicator(elapsed: 60).fraction)
        }
    }
    func testLanguageModelDownloadHasItsOwnStageAndDoesNotClaimAudioCoverage() {
        let value = ProcessingProgress(stage: .speechPreparation, detail: "언어 모델 준비", completed: 0.4, total: 1, unit: .download)
        XCTAssertEqual(value.stage.step, .transcription)
        XCTAssertEqual(value.countLabel, "40% 다운로드")
        XCTAssertEqual(value.fraction, 0.4)
    }

}
