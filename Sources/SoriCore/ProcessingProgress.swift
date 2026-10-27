import Foundation

public struct ProcessingProgress: Equatable, Sendable {
    public enum Step: Int, CaseIterable, Codable, Sendable {
        case transcription, correction, summary, saving
        public var title: String {
            switch self {
            case .transcription: "음성 인식"
            case .correction: "전사문 교정"
            case .summary: "핵심 요약"
            case .saving: "저장"
            }
        }
    }
    public enum Stage: Sendable {
        case finishingRecording, preparing, speechPreparation, transcription, context, correction, analysis, synthesis, saving
        public var step: Step {
            switch self {
            case .finishingRecording, .preparing, .speechPreparation, .transcription: .transcription
            case .context, .correction: .correction
            case .analysis, .synthesis: .summary
            case .saving: .saving
            }
        }
        public var title: String {
            switch self {
            case .finishingRecording: "녹음을 마무리하고 있어요"
            case .preparing: "녹음 파일을 확인하고 있어요"
            case .speechPreparation: "음성 인식을 준비하고 있어요"
            case .transcription: "음성을 텍스트로 옮기고 있어요"
            case .context: "강의 전체의 문맥을 확인하고 있어요"
            case .correction: "전사문을 다듬고 있어요"
            case .analysis: "핵심 요약을 만들고 있어요"
            case .synthesis: "핵심 요약을 마무리하고 있어요"
            case .saving: "정리한 내용을 저장하고 있어요"
            }
        }
        /// Saving is a short final part of the summary, not another user-facing task.
        public var displayStep: Step { step == .saving ? .summary : step }
    }
    public enum Unit: Sendable { case audio, sentences, sections, download }
    public let stage: Stage
    public let detail: String
    public let completed: Double?
    public let total: Double?
    public let unit: Unit
    public let issue: Bool
    public let estimatedDuration: TimeInterval?
    public init(stage: Stage, detail: String, completed: Double? = nil, total: Double? = nil,
                unit: Unit = .sections, issue: Bool = false, estimatedDuration: TimeInterval? = nil) {
        self.stage = stage; self.detail = detail; self.completed = completed; self.total = total; self.unit = unit; self.issue = issue
        self.estimatedDuration = estimatedDuration
    }
    public var fraction: Double? {
        guard let completed, let total, completed.isFinite, total.isFinite, total > 0 else { return nil }
        return min(1, max(0, completed / total))
    }
    public var countLabel: String? {
        guard fraction != nil, let completed, let total else { return nil }
        switch unit {
        case .download: return "\(Int(min(1, max(0, completed / total)) * 100))% 다운로드"
        case .audio: return "\(TimeText.clock(min(max(0, completed), total, Double(Int32.max)))) / \(TimeText.clock(min(total, Double(Int32.max)))) 인식"
        case .sentences: return "\(Int(min(max(0, completed), Double(Int32.max)))) / \(Int(min(total, Double(Int32.max))))문장 확인"
        case .sections: return "\(Int(min(max(0, completed), Double(Int32.max)))) / \(Int(min(total, Double(Int32.max))))구간 완료"
        }
    }

    public struct Indicator: Equatable, Sendable {
        public let fraction: Double?
        public let label: String
        public let isEstimated: Bool
        public let isTakingLonger: Bool
    }

    /// Each bar describes its current stage only. Never invent an overall percentage.
    public func indicator(elapsed: TimeInterval) -> Indicator {
        if issue { return .init(fraction: nil, label: "이어서 정리할 수 있어요", isEstimated: false, isTakingLonger: false) }
        if let fraction {
            let label: String
            switch unit {
            case .audio, .download: label = countLabel ?? "처리 중"
            case .sentences: label = fraction == 1 ? "전사문 확인 완료" : "전사문 확인 중"
            case .sections: label = fraction == 1 ? "내용 확인 완료" : "강의 내용 확인 중"
            }
            return .init(fraction: fraction, label: label, isEstimated: false, isTakingLonger: false)
        }
        if let estimatedDuration, estimatedDuration.isFinite, estimatedDuration > 0 {
            let fraction = EstimatedProgressCurve.fraction(elapsed: elapsed, expectedDuration: estimatedDuration)
            return .init(fraction: fraction, label: "예상 \(Int(fraction * 100))%", isEstimated: true,
                         isTakingLonger: elapsed.isFinite && elapsed > estimatedDuration)
        }
        let label: String
        switch stage {
        case .finishingRecording, .preparing: label = "녹음 파일 확인 중"
        case .speechPreparation: label = unit == .download ? "언어 모델 다운로드 중" : "음성 인식 준비 중"
        case .transcription: label = "음성 인식 중"
        case .context, .correction: label = "교정 준비 중"
        case .analysis: label = "강조한 내용과 발언 근거 확인 중"
        case .synthesis: label = "제목과 핵심 요약 마무리 중"
        case .saving: label = "결과 저장 중"
        }
        return .init(fraction: nil, label: label, isEstimated: false, isTakingLonger: false)
    }
}
