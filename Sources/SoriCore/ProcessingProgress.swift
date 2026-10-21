import Foundation

public struct ProcessingProgress: Equatable, Sendable {
    public enum Step: Int, CaseIterable, Codable, Sendable {
        case transcription, correction, summary, saving
        public var title: String {
            switch self {
            case .transcription: "음성 전사"
            case .correction: "전사문 교정"
            case .summary: "제목·핵심 요약"
            case .saving: "저장"
            }
        }
    }
    public enum Stage: Sendable {
        case finishingRecording, preparing, transcription, context, correction, analysis, synthesis, saving
        public var step: Step {
            switch self {
            case .finishingRecording, .preparing, .transcription: .transcription
            case .context, .correction: .correction
            case .analysis, .synthesis: .summary
            case .saving: .saving
            }
        }
        public var title: String {
            switch self {
            case .finishingRecording: "녹음을 마무리하고 있어요"
            case .preparing: "녹음 파일을 확인하고 있어요"
            case .transcription: "음성을 텍스트로 옮기고 있어요"
            case .context: "강의 전체의 문맥을 확인하고 있어요"
            case .correction: "전사문을 교정하고 있어요"
            case .analysis: "제목과 핵심 요약을 정리하고 있어요"
            case .synthesis: "강의 전체의 요약을 하나로 모으고 있어요"
            case .saving: "정리한 내용을 저장하고 있어요"
            }
        }
    }
    public enum Unit: Sendable { case audio, sentences, sections }
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
        case .audio: return "\(TimeText.clock(min(max(0, completed), Double(Int32.max)))) / \(TimeText.clock(min(total, Double(Int32.max)))) 전사"
        case .sentences: return "\(Int(min(max(0, completed), Double(Int32.max)))) / \(Int(min(total, Double(Int32.max))))문장 확인"
        case .sections: return "\(Int(min(max(0, completed), Double(Int32.max)))) / \(Int(min(total, Double(Int32.max))))구간 완료"
        }
    }
}
