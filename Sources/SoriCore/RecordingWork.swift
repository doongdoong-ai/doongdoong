import Foundation

/// Durable intent, separate from the display status and existing transcript.
public struct RecordingWork: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case recording, transcription, summary }
    public enum State: String, Codable, Sendable { case queued, running, interrupted }
    public enum Cause: String, Codable, Sendable { case sleep, appClosed, unexpected, userStopped }
    public let kind: Kind
    public var state: State
    public var cause: Cause?
    public let requestedAt: Date
    public var step: ProcessingProgress.Step?

    public init(kind: Kind, state: State = .queued, cause: Cause? = nil, requestedAt: Date = Date(), step: ProcessingProgress.Step? = nil) {
        self.kind = kind; self.state = state; self.cause = cause; self.requestedAt = requestedAt; self.step = step
    }
    public mutating func interrupt(_ cause: Cause) { state = .interrupted; self.cause = cause }
    public var title: String {
        if kind == .recording { return "중단된 녹음을 보관했어요" }
        switch step {
        case .transcription: return "음성 전사를 이어서 할 수 있어요"
        case .correction: return "전사문 교정을 이어서 할 수 있어요"
        case .summary: return "핵심 요약을 이어서 할 수 있어요"
        case .saving: return "정리한 내용의 저장을 마칠 수 있어요"
        case nil: return kind == .summary ? "핵심 요약을 이어서 할 수 있어요" : "녹음 정리를 이어서 할 수 있어요"
        }
    }
}

extension Recording {
    /// Repeated launches must not erase intent or convert an interrupted summary
    /// retry into a full transcription that could replace manually edited text.
    @discardableResult public mutating func recoverInterruptedWork() -> Bool {
        if work?.state == .interrupted {
            if status == .recording || status.isProcessing { status = segments.isEmpty ? .queued : completedStatus; return true }
            return false
        }
        guard work != nil || status == .recording || status.isProcessing else { return false }
        if work == nil { work = .init(kind: status == .recording ? .recording : .transcription, state: .running) }
        work?.interrupt(.unexpected)
        status = segments.isEmpty ? .queued : completedStatus
        message = nil
        return true
    }
}
