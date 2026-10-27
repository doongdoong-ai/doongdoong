import Foundation

/// Presentation only: maps elapsed time and a provider-supplied duration to a bar.
/// The clock never marks a stage complete; only a validated response can.
public enum EstimatedProgressCurve {
    public static func fraction(elapsed: TimeInterval, expectedDuration: TimeInterval) -> Double {
        guard elapsed.isFinite, expectedDuration.isFinite, expectedDuration > 0 else { return 0 }
        return 0.9 * (1 - exp(-max(0, elapsed) * 1.8 / expectedDuration))
    }
}
