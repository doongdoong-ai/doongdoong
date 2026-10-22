import SwiftUI
import SoriCore

/// The roadmap shows completed work; the bar belongs only to the active stage.
struct ProcessingProgressView: View {
    @Bindable var store: AppStore
    let recordingID: UUID
    var compact = false
    var condensed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var waiting: Bool { store.queue.contains(recordingID) }
    private var ownsProgress: Bool {
        store.processingID == recordingID || (store.processingID == nil && store.isFinalizing(recordingID))
    }
    private var stopping: Bool {
        store.processingID == recordingID && store.recordings.first(where: { $0.id == recordingID })?.work?.state == .interrupted
    }
    private var progress: ProcessingProgress? {
        if store.isFinalizing(recordingID) {
            return .init(stage: .finishingRecording, detail: "녹음을 저장하고 마지막 음성 구간을 마무리합니다.")
        }
        return store.progress(for: recordingID)
    }
    private var steps: [ProcessingProgress.Step] {
        store.isSummaryOnly(recordingID) ? [.summary] : [.transcription, .correction, .summary]
    }
    private var transcriptReady: Bool {
        ownsProgress && store.processingCompletedSteps.contains(.correction)
            && store.recordings.contains { $0.id == recordingID && !$0.segments.isEmpty }
    }
    private var title: String {
        if stopping { return "작업을 멈추고 있어요" }
        if waiting { return "정리 순서를 기다리고 있어요" }
        return progress?.stage.title ?? "녹음을 정리할 준비를 하고 있어요"
    }
    private var detail: String {
        if stopping { return "녹음과 완료한 작업을 보관합니다. 나중에 이어서 정리할 수 있어요." }
        if waiting {
            let ahead = (store.queue.firstIndex(of: recordingID) ?? 0) + (store.processingID == nil ? 0 : 1)
            return ahead > 0 ? "앞선 녹음 \(ahead)개가 끝나면 자동으로 시작합니다." : "곧 시작합니다. 녹음 파일은 저장되어 있어요."
        }
        if transcriptReady { return "전사문은 먼저 읽을 수 있어요. 제목과 강조한 내용을 정리하고 있습니다." }
        return progress?.detail ?? "저장된 녹음에서 이어서 진행합니다."
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: compact ? 14 : condensed ? 16 : 24) {
                heading
                if !stopping {
                    if compact {
                        if !waiting, let progress { meter(progress) }
                    } else {
                        roadmap
                    }
                }
                footer(now: context.date)
            }
            .padding(compact ? 18 : condensed ? 20 : 26)
            .frame(maxWidth: compact ? .infinity : 510, alignment: .leading)
            .background(SoriTheme.surface, in: RoundedRectangle(cornerRadius: compact ? 12 : 18))
            .overlay(RoundedRectangle(cornerRadius: compact ? 12 : 18).stroke(SoriTheme.line, lineWidth: 1))
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            if !compact && !condensed && !store.isFinalizing(recordingID) {
                Label("녹음 저장됨", systemImage: "checkmark.circle")
                    .font(.system(size: 13)).foregroundStyle(SoriTheme.secondary)
            }
            Text(title).font(.system(size: compact ? 15 : 21, weight: .semibold))
                .foregroundStyle(SoriTheme.ink).fixedSize(horizontal: false, vertical: true)
            Text(detail).font(.system(size: 13)).foregroundStyle(SoriTheme.secondary)
                .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var roadmap: some View {
        VStack(alignment: .leading, spacing: condensed ? 12 : 18) {
            ForEach(steps, id: \.self) { step in
                let current = !waiting && step == progress?.stage.displayStep
                let issue = ownsProgress && store.processingIssues.contains(step)
                let complete = ownsProgress && !current && store.processingCompletedSteps.contains(step)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: issue ? "exclamationmark.circle" : complete ? "checkmark.circle.fill" : current ? "circle.inset.filled" : "circle")
                            .font(.system(size: 16)).frame(width: 20)
                            .foregroundStyle(issue ? Color.orange : complete ? SoriTheme.green : current ? SoriTheme.ink : SoriTheme.faint)
                            .accessibilityHidden(true)
                        Text(step.title).font(.system(size: 14, weight: current ? .semibold : .regular))
                            .foregroundStyle(current || complete ? SoriTheme.ink : SoriTheme.secondary)
                        Spacer(minLength: 8)
                        Text(issue ? "확인 필요" : complete ? "완료" : current ? "진행 중" : "대기")
                            .font(.system(size: 13)).foregroundStyle(issue ? Color.orange : SoriTheme.secondary)
                    }.accessibilityElement(children: .combine)
                    if current, let progress { meter(progress).padding(.leading, 30) }
                }
            }
        }
    }

    private func meter(_ progress: ProcessingProgress) -> some View {
        let elapsed = ownsProgress ? store.processingEstimateStartedUptime.map { max(0, ProcessInfo.processInfo.systemUptime - $0) } ?? 0 : 0
        let indicator = progress.indicator(elapsed: elapsed)
        return VStack(alignment: .leading, spacing: 8) {
            if let fraction = indicator.fraction {
                ProgressView(value: fraction).progressViewStyle(.linear).tint(SoriTheme.ink)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: fraction)
                    .accessibilityLabel(progress.stage.displayStep.title + (indicator.isEstimated ? " 예상 진행률" : " 진행률"))
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if indicator.fraction == nil && !progress.issue {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                }
                Text(indicator.label).monospacedDigit()
                Spacer(minLength: 0)
                if indicator.isEstimated {
                    Text("시간 기준 추정")
                        .help("강의 길이와 경과 시간에 따른 예상치입니다. 응답을 확인한 뒤에만 완료로 표시합니다.")
                }
            }.font(.system(size: 13)).foregroundStyle(SoriTheme.secondary)
            if indicator.isTakingLonger {
                Text("예상보다 시간이 걸리고 있어요. 응답이 도착하면 결과를 확인합니다.")
                    .font(.system(size: 13)).foregroundStyle(SoriTheme.secondary)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func footer(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !compact && !condensed {
                Rectangle().fill(SoriTheme.line).frame(height: 1).accessibilityHidden(true)
                Text(progress?.stage.step == .correction
                     ? "교정이 끝나면 전사문을 먼저 읽을 수 있어요."
                     : "다른 녹음을 열어도 정리는 계속됩니다.")
                    .font(.system(size: 13)).foregroundStyle(SoriTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                if !waiting, ownsProgress, let started = store.processingStartedAt {
                    Text("\(TimeText.clock(max(0, now.timeIntervalSince(started)))) 경과")
                        .monospacedDigit().accessibilityLabel("정리 시작 후 \(TimeText.clock(max(0, now.timeIntervalSince(started)))) 경과")
                } else if compact {
                    Text("녹음은 저장되어 있어요.")
                }
                Spacer(minLength: 8)
                if !store.isFinalizing(recordingID) {
                    Button(waiting ? "대기 취소" : "나중에 이어하기") { store.cancelProcessing(recordingID) }
                        .buttonStyle(.plain).disabled(stopping)
                        .help("지금 정리를 멈추고 녹음과 완료한 작업을 보관합니다.")
                }
            }.font(.system(size: 13)).foregroundStyle(SoriTheme.secondary)
        }
    }
}
