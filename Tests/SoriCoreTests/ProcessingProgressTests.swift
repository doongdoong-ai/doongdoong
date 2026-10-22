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
        XCTAssertEqual(ProcessingProgress(stage: .transcription, detail: "", completed: 60, total: 120, unit: .audio).countLabel, "01:00 / 02:00 전사")
        XCTAssertNotNil(ProcessingProgress(stage: .transcription, detail: "", completed: .greatestFiniteMagnitude, total: .greatestFiniteMagnitude, unit: .audio).countLabel)
    }
    func testLanguageModelDownloadHasItsOwnStageAndDoesNotClaimAudioCoverage() {
        let value = ProcessingProgress(stage: .speechPreparation, detail: "언어 모델 준비", completed: 0.4, total: 1, unit: .download)
        XCTAssertEqual(value.stage.step, .transcription)
        XCTAssertEqual(value.countLabel, "40% 다운로드")
        XCTAssertEqual(value.fraction, 0.4)
    }

}
