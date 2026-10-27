import XCTest
@testable import SoriCore

final class EstimatedProgressCurveTests: XCTestCase {
    func testConservativeClockProgressIsMonotonicAndCannotCompleteWork() {
        let values = stride(from: 0.0, through: 3600.0, by: 5).map {
            EstimatedProgressCurve.fraction(elapsed: $0, expectedDuration: 300)
        }
        XCTAssertEqual(values, values.sorted())
        XCTAssertEqual(values.first, 0)
        XCTAssertTrue(values.allSatisfy { $0 <= 0.9 })
        XCTAssertEqual(EstimatedProgressCurve.fraction(elapsed: 300, expectedDuration: 300), 0.751, accuracy: 0.005)
        XCTAssertEqual(EstimatedProgressCurve.fraction(elapsed: -.infinity, expectedDuration: 300), 0)
        XCTAssertEqual(EstimatedProgressCurve.fraction(elapsed: -1, expectedDuration: 300), 0)
    }
}
