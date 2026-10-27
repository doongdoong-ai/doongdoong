import SwiftUI
import SoriCore

/// Window-filling recording workspace. The native editor has one stable identity
/// while the recorder contracts and the writing area expands around it.
struct RecordingWorkspaceView: View {
    @Bindable var store: AppStore
    let recording: Recording
    @State private var draft: RecordingNotesDraft
    @State private var editor = MarkdownEditorController()
    @State private var collapsed: Bool
    @State private var preview: Bool
    @State private var showMarkdownHelp = false

    init(store: AppStore, recording: Recording) {
        self.store = store; self.recording = recording
        _draft = State(initialValue: RecordingNotesDraft(store: store, recording: recording))
        let args = ProcessInfo.processInfo.arguments
        _collapsed = State(initialValue: args.contains("--recorder-collapsed-preview"))
        _preview = State(initialValue: args.contains("--markdown-preview"))
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
                    notes
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
        .onChange(of: recording.notes) { _, value in draft.synchronize(value) }
        .onChange(of: store.unsavedIDs) { _, _ in draft.acknowledgeSave() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("BungBungiWillSave"))) { _ in
            editor.endComposition(); draft.flush()
        }
        .onDisappear { draft.flush() }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text("수업 필기").font(.system(size: 27, weight: .semibold)).tracking(-0.8)
                Spacer()
                HStack(spacing: 2) {
                    modeButton("작성", symbol: "pencil.line", selected: !preview) { preview = false; editor.focus() }
                    modeButton("미리보기", symbol: "doc.text", selected: preview) {
                        editor.blur(); preview = true
                    }
                }.padding(3).background(SoriTheme.sidebar, in: RoundedRectangle(cornerRadius: 9))
            }.padding(.bottom, 23)

            HStack(spacing: 3) {
                formatButton("제목", symbol: "textformat.size", command: .heading)
                formatButton("굵게 · ⌘B", symbol: "bold", command: .bold)
                formatButton("기울임 · ⌘I", symbol: "italic", command: .italic)
                toolbarDivider
                formatButton("글머리 목록", symbol: "list.bullet", command: .bullet)
                formatButton("체크 목록", symbol: "checklist", command: .task)
                formatButton("인용", symbol: "text.quote", command: .quote)
                formatButton("코드", symbol: "chevron.left.forwardslash.chevron.right", command: .code)
                Spacer(minLength: 6)
                Button {
                    preview = false
                    editor.perform(.timestamp(TimeText.clock(store.audio.recordingTime)))
                } label: {
                    Label("시간 넣기", systemImage: "clock").font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 9).frame(height: 32)
                }.buttonStyle(NotesToolStyle()).help("현재 녹음 시간을 필기에 남깁니다")
            }.padding(.bottom, 12)
            Rectangle().fill(SoriTheme.line).frame(height: 1)

            ZStack(alignment: .topLeading) {
                // Do not branch on collapsed/preview here: keep undo, selection,
                // scroll position and marked text in this same NSTextView.
                MarkdownNotesEditor(text: $draft.text, controller: editor, isEditing: !preview)
                    .opacity(preview ? 0 : 1)
                    .allowsHitTesting(!preview).accessibilityHidden(preview)
                if preview { MarkdownNotesPreview(text: draft.text) }
                if draft.text.isEmpty {
                    VStack(alignment: .leading, spacing: 13) {
                        Text("지금, 기억해 둘 내용").font(.system(size: 20, weight: .medium)).foregroundStyle(SoriTheme.secondary)
                        Text("교수님이 강조한 내용, 떠오른 질문을 적어보세요.\n마크다운으로 쓰면 더 깔끔하게 정리할 수 있어요.")
                            .font(.system(size: 14)).foregroundStyle(SoriTheme.secondary.opacity(0.75)).lineSpacing(6)
                        Text(verbatim: "# 제목     **굵게**     - 목록")
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(SoriTheme.secondary.opacity(0.6)).padding(.top, 6)
                    }.padding(.leading, 6).padding(.top, 26).allowsHitTesting(false).accessibilityHidden(true)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                // Native content should reflow, never crossfade on every keystroke.
                .transaction { $0.animation = nil }

            HStack(spacing: 6) {
                let failed = store.unsavedIDs.contains(recording.id)
                Image(systemName: failed ? "exclamationmark.circle" : draft.isDirty ? "ellipsis" : "checkmark")
                Text(failed ? "저장하지 못했습니다" : draft.isDirty ? "저장 중…" : "자동 저장됨")
                if failed { Button("다시 저장") { draft.flush() }.buttonStyle(.plain).underline() }
                Spacer()
                Button { showMarkdownHelp.toggle() } label: {
                    HStack(spacing: 5) { Text("마크다운"); Image(systemName: "questionmark.circle") }
                }.buttonStyle(.plain).help("마크다운 사용법")
                    .popover(isPresented: $showMarkdownHelp, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 15) {
                            Text("필기의 기본 문법").font(.system(size: 15, weight: .semibold))
                            Text(verbatim: "# 제목\n**굵게**  ·  *기울임*\n- 목록\n- [ ] 할 일\n> 인용\n`코드`")
                                .font(.system(size: 14, design: .monospaced)).lineSpacing(8)
                            Text("목록에서 Enter를 누르면 이어 쓰고,\n빈 항목에서 한 번 더 누르면 마칩니다.")
                                .font(.system(size: 12)).foregroundStyle(SoriTheme.secondary).lineSpacing(4)
                        }.padding(22).frame(width: 280, alignment: .leading)
                    }
            }.font(.system(size: 12)).foregroundStyle(store.unsavedIDs.contains(recording.id) ? SoriTheme.recording : SoriTheme.secondary)
                .padding(.top, 12).padding(.horizontal, 6)
        }.frame(maxWidth: 820).frame(maxWidth: .infinity)
    }

    private var toolbarDivider: some View {
        Rectangle().fill(SoriTheme.line).frame(width: 1, height: 17).padding(.horizontal, 6)
    }

    private func formatButton(_ title: String, symbol: String, command: MarkdownCommand) -> some View {
        Button { preview = false; editor.perform(command) } label: {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium)).frame(width: 32, height: 32)
        }.buttonStyle(NotesToolStyle()).help(title).accessibilityLabel(title)
    }

    private func modeButton(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 12, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 12).frame(height: 29)
                .background(selected ? SoriTheme.paper : .clear, in: RoundedRectangle(cornerRadius: 7))
                .foregroundStyle(selected ? SoriTheme.ink : SoriTheme.secondary)
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func finish() {
        editor.endComposition(); draft.flush()
        Task { await store.stopRecording() }
    }
}

private struct NotesToolStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ToolBody(configuration: configuration)
    }
    private struct ToolBody: View {
        let configuration: Configuration
        @State private var hovered = false
        var body: some View {
            configuration.label.foregroundStyle(SoriTheme.secondary)
                .background(hovered || configuration.isPressed ? SoriTheme.sidebar : .clear, in: RoundedRectangle(cornerRadius: 6))
                .onHover { hovered = $0 }
        }
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
