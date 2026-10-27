import SwiftUI
import SoriCore

/// Window-filling recording workspace. The native editor has one stable identity
/// while the recorder contracts and the writing area expands around it.
struct RecordingWorkspaceView: View {
    @Bindable var store: AppStore
    let recording: Recording
    @State private var collapsed: Bool

    init(store: AppStore, recording: Recording) {
        self.store = store; self.recording = recording
        let args = ProcessInfo.processInfo.arguments
        _collapsed = State(initialValue: args.contains("--recorder-collapsed-preview"))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(recording.recordsAudioOnly ? "녹음" : "강의 기록")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Image(systemName: "folder").font(.system(size: 12))
                Text(store.projects.first(where: { $0.id == recording.projectID })?.name ?? "작업 폴더")
                    .font(.system(size: 13)).lineLimit(1)
            }
            .foregroundStyle(SoriTheme.secondary)
            .padding(.leading, 96).padding(.trailing, 28).frame(height: 48)

            GeometryReader { geometry in
                let sidebar = min(380, max(320, geometry.size.width * 0.30))
                ZStack(alignment: .topLeading) {
                    RecordingNotesPane(store: store, recording: recording)
                        .padding(.horizontal, collapsed ? 64 : 38)
                        .padding(.leading, collapsed ? 0 : sidebar)
                        .padding(.top, collapsed ? 90 : 22)
                        .padding(.bottom, 20)
                        .frame(width: geometry.size.width, height: geometry.size.height)

                    RecorderPanel(audio: store.audio, collapsed: collapsed,
                                  audioOnly: recording.recordsAudioOnly,
                                  pause: store.toggleRecordingPause,
                                  stop: finish,
                                  toggle: {
                                      withAnimation(.spring(response: 0.48, dampingFraction: 0.88)) { collapsed.toggle() }
                                  })
                        .frame(width: collapsed ? 326 : sidebar - 20,
                               height: collapsed ? 64 : geometry.size.height - 32)
                        .padding(.leading, 16).padding(.top, 12)
                        .zIndex(1)
                }
            }
        }
        .background(SoriTheme.paper)
    }

    private func finish() {
        Task { await store.stopRecording() }
    }
}

private struct RecorderPanel: View {
    let audio: AudioEngine
    let collapsed: Bool
    let audioOnly: Bool
    let pause: () -> Void
    let stop: () -> Void
    let toggle: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let foreground = collapsed ? Color.white : SoriTheme.ink
            ZStack {
                RoundedRectangle(cornerRadius: collapsed ? 18 : 20)
                    .fill(collapsed ? SoriTheme.ink : SoriTheme.sidebar)

                HStack(spacing: 9) {
                    RecordingPulse(paused: audio.isPausedRecording)
                    Text(audio.isPausedRecording ? "일시 정지" : "녹음 중")
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(SoriTheme.secondary)
                }.opacity(collapsed ? 0 : 1)
                    .position(x: size.width / 2, y: size.height * 0.31 - 65)
                    .accessibilityHidden(collapsed)

                RecordingClock(audio: audio)
                    .frame(width: 270, height: 80)
                    .scaleEffect(collapsed ? 0.33 : 1)
                    .foregroundStyle(foreground)
                    .position(x: collapsed ? 104 : size.width / 2, y: collapsed ? 32 : size.height * 0.31)

                RecordingSignal(audio: audio, compact: collapsed)
                    .frame(width: collapsed ? 25 : size.width - 72, height: collapsed ? 24 : 80)
                    .position(x: collapsed ? 31 : size.width / 2, y: collapsed ? 32 : size.height * 0.31 + 100)

                Button(action: toggle) {
                    Image(systemName: collapsed ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 13, weight: .medium)).frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(foreground.opacity(0.6))
                    .help(collapsed ? "녹음 패널 펼치기" : "녹음 패널 접기 · 필기 공간 넓히기")
                    .accessibilityLabel(collapsed ? "녹음 패널 펼치기" : "녹음 패널 접기")
                    .position(x: size.width - 27, y: 32)

                Button(action: pause) {
                    Image(systemName: audio.isPausedRecording ? "play.fill" : "pause.fill")
                        .font(.system(size: collapsed ? 14 : 19, weight: .semibold))
                        .frame(width: collapsed ? 38 : 56, height: collapsed ? 38 : 56)
                        .background(collapsed ? Color.white.opacity(0.08) : SoriTheme.paper, in: Circle())
                }.buttonStyle(.plain).foregroundStyle(foreground)
                    .help(audio.isPausedRecording ? "녹음 계속하기 · ⇧⌘R" : "일시 정지 · ⇧⌘R")
                    .accessibilityLabel(audio.isPausedRecording ? "녹음 계속하기" : "녹음 일시 정지")
                    .position(x: collapsed ? size.width - 116 : size.width / 2 - 78, y: collapsed ? 32 : size.height - 177)

                Button(action: stop) {
                    HStack(spacing: 10) {
                        Image(systemName: "stop.fill").font(.system(size: collapsed ? 12 : 14))
                        if !collapsed { Text("녹음 마치기").font(.system(size: 14, weight: .semibold)).transition(.opacity) }
                    }.frame(width: collapsed ? 38 : 138, height: collapsed ? 38 : 56)
                        .background(collapsed ? Color.white.opacity(0.12) : SoriTheme.ink, in: Capsule())
                        .foregroundStyle(.white)
                }.buttonStyle(.plain).help("녹음 마치기 · ⌘R").accessibilityLabel("녹음 마치기")
                    .position(x: collapsed ? size.width - 72 : size.width / 2 + 33, y: collapsed ? 32 : size.height - 177)

                VStack(spacing: 9) {
                    Image(systemName: audioOnly ? "waveform" : "sparkles").font(.system(size: 16))
                    Text(audioOnly ? "녹음과 필기를 함께 보관합니다.\n필요할 때 AI로 정리할 수 있어요." : "수업이 끝나면 녹음을 마쳐주세요.\nAI가 전사문과 핵심 요약을 정리합니다.")
                        .font(.system(size: 12)).lineSpacing(5).multilineTextAlignment(.center)
                }.foregroundStyle(SoriTheme.secondary.opacity(0.8))
                    .opacity(collapsed ? 0 : 1).accessibilityHidden(collapsed)
                    .position(x: size.width / 2, y: size.height - 78)
            }
        }
    }
}

/// Only these small leaf views observe the 20 Hz audio meter/timer updates.
private struct RecordingClock: View {
    let audio: AudioEngine
    var body: some View {
        Text(TimeText.clock(audio.recordingTime))
            .font(.system(size: 57, weight: .light, design: .rounded)).monospacedDigit().tracking(-1.5)
            .accessibilityLabel("녹음 시간 \(TimeText.clock(audio.recordingTime))")
            .transaction { $0.animation = nil }
    }
}

private struct RecordingPulse: View {
    let paused: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: paused)) { timeline in
            let phase = (sin(timeline.date.timeIntervalSinceReferenceDate * 3) + 1) / 2
            ZStack {
                Circle().fill(SoriTheme.recording.opacity(paused ? 0 : 0.10 + phase * 0.10)).frame(width: 18, height: 18)
                    .scaleEffect(paused ? 1 : 0.8 + phase * 0.25)
                Circle().fill(paused ? SoriTheme.secondary : SoriTheme.recording).frame(width: 7, height: 7)
            }
        }.frame(width: 18, height: 18).accessibilityHidden(true)
    }
}

private struct RecordingSignal: View {
    let audio: AudioEngine
    let compact: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: audio.isPausedRecording)) { timeline in
            Canvas { context, size in
                let levels = audio.liveLevels
                let count = compact ? 5 : 48
                let step = size.width / CGFloat(count)
                let fraction = min(1, max(0, (ProcessInfo.processInfo.systemUptime - audio.meterUpdatedAt) / 0.05))
                let breathing = (sin(timeline.date.timeIntervalSinceReferenceDate * 3) + 1) / 2
                for index in 0..<count {
                    let offset = max(0, levels.count - count - 1) + index
                    let a = Double(levels[min(offset, levels.count - 1)])
                    let b = Double(levels[min(offset + 1, levels.count - 1)])
                    let amplitude = audio.isPausedRecording ? 0 : a + (b - a) * fraction
                    // The quiet floor is a small activity light, not invented speech.
                    let height = max(compact ? 3 : 3.5, amplitude * (size.height - 4))
                    let width = compact ? 2.5 : 3
                    let rect = CGRect(x: CGFloat(index) * step + (step - width) / 2, y: (size.height - height) / 2, width: width, height: height)
                    let color = audio.isPausedRecording ? SoriTheme.faint : SoriTheme.recording.opacity(0.65 + breathing * 0.25)
                    context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color))
                }
            }
        }.accessibilityLabel(audio.isPausedRecording ? "녹음 일시 정지" : "녹음 중, 마이크 입력 파형")
    }
}
