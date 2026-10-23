import SwiftUI
import SoriCore

struct RecoveryBanner: View {
    @Bindable var store: AppStore
    let recording: Recording
    private var live: Bool { store.recordingID == recording.id }
    private var recovering: Bool { store.recoveringIDs.contains(recording.id) }
    private var description: String {
        if recovering { return "저장된 음성의 길이와 재생 상태를 확인하고 있어요. 원본은 그대로 보관합니다." }
        if live { return "Mac이 잠자기에 들어가 녹음을 멈췄어요. 잠든 동안의 소리는 녹음되지 않았습니다. 준비되면 아래에서 계속 녹음하세요." }
        if recording.work?.kind == .recording { return "중단되기 전 저장된 음성을 보관했어요. 재생해 확인하거나 이 부분의 정리를 시작할 수 있습니다." }
        if recording.work?.kind == .summary { return "전사문과 메모는 그대로예요. 핵심 요약 작업을 이어서 진행합니다." }
        return "완료한 전사 구간과 검증된 교정 결과를 이어서 사용합니다. 녹음과 메모는 그대로 보관되어 있어요."
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: live ? "pause.circle" : "arrow.clockwise.circle").font(.system(size: 17))
                Text(recovering ? "저장된 음성을 확인하고 있어요" : live ? "녹음이 일시 정지됐어요" : recording.work?.title ?? "중단된 작업")
                    .font(.system(size: 15, weight: .semibold))
            }.foregroundStyle(SoriTheme.ink)
            Text(description).font(.system(size: 13)).lineSpacing(4).foregroundStyle(SoriTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !live {
                HStack(spacing: 14) {
                    Button(recording.work?.kind == .recording ? "저장된 음성 정리" : "이어서 정리") { store.resumeWork(recording.id) }
                        .buttonStyle(PrimaryButtonStyle()).disabled(!store.canResumeWork(recording.id))
                    if recording.work?.kind == .recording && (recording.audioFileName == nil || recording.duration <= 0) {
                        Button("음성 다시 확인") { Task { await store.recoverRecordings() } }
                            .buttonStyle(.plain).foregroundStyle(SoriTheme.secondary).disabled(recovering)
                    } else if !recovering && !store.canResumeWork(recording.id) && !store.isPreparingForSleep && store.processingID != recording.id {
                        Button("설정 확인") { NotificationCenter.default.post(name: Notification.Name("BungBungiShowSettings"), object: nil, userInfo: ["section": store.settings.transcriptionReady ? "providers" : "speech"]) }
                            .buttonStyle(.plain).foregroundStyle(SoriTheme.secondary)
                    }
                    Spacer()
                    if recovering || store.isPreparingForSleep { ProgressView().controlSize(.small) }
                }.font(.system(size: 13))
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(SoriTheme.sidebar.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(SoriTheme.ink.opacity(0.08), lineWidth: 1))
    }
}
