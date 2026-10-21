import XCTest
@testable import SoriCore

final class CorrectionProgressEstimateTests: XCTestCase {
    func testConservativeClockProgressIsMonotonicAndCannotCompleteWork() {
        XCTAssertEqual(CorrectionProgressEstimate.duration(characterCount: 0), 120)
        XCTAssertGreaterThan(CorrectionProgressEstimate.duration(characterCount: 40_000),
                             CorrectionProgressEstimate.duration(characterCount: 10_000))
        let values = stride(from: 0.0, through: 3600.0, by: 5).map {
            CorrectionProgressEstimate.fraction(elapsed: $0, expectedDuration: 300)
        }
        XCTAssertEqual(values, values.sorted())
        XCTAssertEqual(values.first, 0)
        XCTAssertTrue(values.allSatisfy { $0 <= 0.9 })
        XCTAssertEqual(CorrectionProgressEstimate.fraction(elapsed: 300, expectedDuration: 300), 0.751, accuracy: 0.005)
        XCTAssertEqual(CorrectionProgressEstimate.fraction(elapsed: -.infinity, expectedDuration: 300), 0)
        XCTAssertEqual(CorrectionProgressEstimate.fraction(elapsed: -1, expectedDuration: 300), 0)
    }
}
