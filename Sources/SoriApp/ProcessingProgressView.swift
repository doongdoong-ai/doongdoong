import SwiftUI
import SoriCore

/// Audio progress is measured; model inference has an explicitly labeled clock estimate.
struct ProcessingProgressView: View {
    @Bindable var store: AppStore
    let recordingID: UUID
    var compact = false

    private var waiting: Bool { store.queue.contains(recordingID) }
    private var progress: ProcessingProgress? { store.progress(for: recordingID) }
    private var title: String {
        if waiting { return "정리 순서를 기다리고 있어요" }
        if store.isFinalizing(recordingID) { return "녹음을 마무리하고 있어요" }
        return progress?.stage.title ?? "녹음을 정리할 준비를 하고 있어요"
    }
    private var detail: String {
        if waiting {
            let ahead = (store.queue.firstIndex(of: recordingID) ?? 0) + (store.processingID == nil ? 0 : 1)
            return ahead > 0 ? "앞선 녹음 \(ahead)개가 끝나면 자동으로 시작합니다." : "곧 시작합니다. 녹음 파일은 저장되어 있어요."
        }
        return progress?.detail ?? "녹음 파일은 저장되어 있어요."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 22) {
            HStack(alignment: .top, spacing: 14) {
                if compact { ProgressView().controlSize(.small).padding(.top, 3).accessibilityHidden(true) }
                VStack(alignment: .leading, spacing: 7) {
                    Text(title).font(.system(size: compact ? 15 : 21, weight: .semibold))
                        .foregroundStyle(SoriTheme.ink).fixedSize(horizontal: false, vertical: true)
                    Text(detail).font(.system(size: 13)).foregroundStyle(SoriTheme.secondary)
                        .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if !waiting, let progress {
                VStack(alignment: .leading, spacing: 8) {
                    if let expected = progress.estimatedDuration, let started = store.processingStepStartedUptime {
                        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                            let fraction = CorrectionProgressEstimate.fraction(elapsed: ProcessInfo.processInfo.systemUptime - started, expectedDuration: expected)
                            VStack(alignment: .leading, spacing: 8) {
                                ProgressView(value: fraction).progressViewStyle(.linear).tint(SoriTheme.ink)
                                    .animation(.linear(duration: 0.3), value: fraction)
                                    .accessibilityLabel("교정 예상 진행률")
                                Text("예상 진행률").font(.system(size: 13)).foregroundStyle(SoriTheme.secondary)
                            }
                        }
                    } else if let fraction = progress.fraction {
                        ProgressView(value: fraction).progressViewStyle(.linear).tint(SoriTheme.ink)
                            .accessibilityLabel(progress.stage.step.title + " 진행률")
                        if let label = progress.countLabel {
                            Text(label).font(.system(size: 13)).monospacedDigit().foregroundStyle(SoriTheme.secondary)
                        }
                    } else {
                        ProgressView().progressViewStyle(.linear).tint(SoriTheme.ink)
                            .accessibilityLabel(progress.stage.title)
                    }
                }
                if !compact {
                    VStack(alignment: .leading, spacing: 15) {
                        ForEach(store.processingSummaryOnly ? [.summary, .saving] : ProcessingProgress.Step.allCases, id: \.self) { step in
                            let current = step == progress.stage.step
                            let issue = store.processingIssues.contains(step)
                            let complete = store.processingCompletedSteps.contains(step)
                            HStack(spacing: 11) {
                                Image(systemName: issue ? "exclamationmark.circle" : complete ? "checkmark.circle.fill" : current ? "circle.inset.filled" : "circle")
                                    .font(.system(size: 15)).frame(width: 18)
                                Text(step.title).font(.system(size: 14, weight: current ? .medium : .regular))
                                Spacer()
                                if issue { Text("재시도 필요").font(.system(size: 12)) }
                                else if complete { Text("완료").font(.system(size: 12)) }
                            }.foregroundStyle(issue ? Color.orange : current || complete ? SoriTheme.ink : SoriTheme.secondary.opacity(0.65))
                        }
                    }.padding(.vertical, 2)
                }
            }
            HStack(spacing: 12) {
                if !waiting, progress != nil, let started = store.processingStartedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("\(TimeText.clock(context.date.timeIntervalSince(started))) 경과")
                            .font(.system(size: 12)).monospacedDigit().foregroundStyle(SoriTheme.secondary)
                    }.accessibilityLabel("처리 경과 시간")
                } else { Text("다른 녹음을 확인해도 계속 진행됩니다.").font(.system(size: 12)).foregroundStyle(SoriTheme.secondary) }
                Spacer()
                if !store.isFinalizing(recordingID) {
                    Button(waiting ? "대기 취소" : "정리 중지") { store.cancelProcessing(recordingID) }
                        .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(SoriTheme.secondary)
                        .help("녹음과 저장된 전사문은 보관합니다.")
                }
            }
        }.padding(compact ? 16 : 28)
            .frame(maxWidth: compact ? .infinity : 480, alignment: .leading)
            .background(SoriTheme.surface, in: RoundedRectangle(cornerRadius: compact ? 12 : 18))
            .overlay(RoundedRectangle(cornerRadius: compact ? 12 : 18).stroke(SoriTheme.ink.opacity(0.08), lineWidth: 1))
    }
}
