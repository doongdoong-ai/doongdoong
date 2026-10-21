import Foundation

/// A deliberately conservative UX estimate, not a measured model throughput.
/// The clock can never mark a stage complete; only a validated response can.
public enum CorrectionProgressEstimate {
    public static func duration(characterCount: Int) -> TimeInterval {
        min(3600, max(120, 60 + Double(max(0, characterCount)) * 0.012))
    }
    public static func fraction(elapsed: TimeInterval, expectedDuration: TimeInterval) -> Double {
        guard elapsed.isFinite, expectedDuration.isFinite, expectedDuration > 0 else { return 0 }
        return 0.9 * (1 - exp(-max(0, elapsed) * 1.8 / expectedDuration))
    }
}
