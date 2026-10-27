import SwiftUI
import SoriCore

/// One document surface for both a live recording and its saved notes.
struct RecordingNotesPane: View {
    @Bindable var store: AppStore
    let recording: Recording
    var showsTitle = true
    @State private var draft: RecordingNotesDraft
    @State private var editor = MarkdownEditorController()
    @State private var showHelp = false

    init(store: AppStore, recording: Recording, showsTitle: Bool = true) {
        self.store = store; self.recording = recording; self.showsTitle = showsTitle
        _draft = State(initialValue: RecordingNotesDraft(store: store, recording: recording))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                if showsTitle { Text("수업 필기").font(.system(size: 24, weight: .semibold)).tracking(-0.5) }
                Spacer()
                Button {
                    let time = store.recordingID == recording.id ? store.audio.recordingTime : store.audio.currentTime
                    editor.perform(.timestamp(TimeText.clock(time)))
                } label: { Image(systemName: "clock").font(.system(size: 15)).frame(width: 30, height: 32) }
                    .buttonStyle(.plain).help("현재 음성 시간을 필기에 넣기").accessibilityLabel("현재 음성 시간 넣기")
                Menu {
                    Button("제목") { editor.perform(.heading) }
                    Button("굵게 · ⌘B") { editor.perform(.bold) }
                    Button("기울임 · ⌘I") { editor.perform(.italic) }
                    Button("형광펜") { editor.perform(.highlight) }
                    Button("취소선") { editor.perform(.strikethrough) }
                    Divider()
                    Button("글머리 목록") { editor.perform(.bullet) }
                    Button("번호 목록") { editor.perform(.ordered) }
                    Button("체크 목록 · ⇧⌘X") { editor.perform(.toggleTask) }
                    Button("인용") { editor.perform(.quote) }
                    Button("코드") { editor.perform(.code) }
                    Button("링크 · ⌘K") { editor.perform(.link) }
                    Divider()
                    Button("마크다운 복사") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(draft.text, forType: .string)
                        store.notify("필기를 복사했습니다")
                    }.disabled(draft.text.isEmpty)
                    Button("편집 도움말") { showHelp = true }
                } label: { Image(systemName: "ellipsis").font(.system(size: 17)).frame(width: 26, height: 32) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("필기 서식과 도구").accessibilityLabel("필기 서식과 도구")
            }.foregroundStyle(SoriTheme.secondary).padding(.horizontal, 8).padding(.bottom, showsTitle ? 15 : 0)

            ZStack(alignment: .topLeading) {
                MarkdownNotesEditor(text: $draft.text, controller: editor)
                if draft.text.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("필기를 시작하세요.").font(.system(size: 16))
                        Text("# 제목, - 목록처럼 쓰면 서식이 바로 적용됩니다.")
                            .font(.system(size: 13)).foregroundStyle(SoriTheme.secondary.opacity(0.7))
                    }.foregroundStyle(SoriTheme.secondary).padding(.leading, 8).padding(.top, 24)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).transaction { $0.animation = nil }

            HStack(spacing: 6) {
                let failed = store.unsavedIDs.contains(recording.id)
                Image(systemName: failed ? "exclamationmark.circle" : draft.isDirty ? "ellipsis" : "checkmark")
                Text(failed ? "저장하지 못했습니다" : draft.isDirty ? "저장 중…" : "자동 저장됨")
                if failed { Button("다시 저장") { draft.flush() }.buttonStyle(.plain).underline() }
                Spacer()
                Button { showHelp.toggle() } label: { Image(systemName: "questionmark.circle").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).help("편집 도움말").accessibilityLabel("필기 편집 도움말")
                    .popover(isPresented: $showHelp, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 15) {
                            Text("쓰는 순간 정리되는 필기").font(.system(size: 15, weight: .semibold))
                            Text("수정할 곳을 클릭하면 그 줄의 문법이 드러납니다. 다른 줄로 옮기면 다시 서식으로 보입니다.")
                                .font(.system(size: 13)).lineSpacing(5)
                            Text(verbatim: "# 제목\n**굵게**  ·  *기울임*  ·  ==형광펜==\n- 목록  ·  - [ ] 할 일\n> 인용  ·  `코드`")
                                .font(.system(size: 12, design: .monospaced)).lineSpacing(7)
                            Text("목록: Enter로 이어 쓰기, Tab / ⇧Tab으로 들여쓰기\n굵게 ⌘B · 기울임 ⌘I · 링크 ⌘K · 찾기 ⌘F")
                                .font(.system(size: 12)).foregroundStyle(SoriTheme.secondary).lineSpacing(5)
                        }.padding(22).frame(width: 330, alignment: .leading)
                    }
            }.font(.system(size: 12)).foregroundStyle(store.unsavedIDs.contains(recording.id) ? SoriTheme.recording : SoriTheme.secondary)
                .padding(.top, 8).padding(.horizontal, 8)
        }.frame(maxWidth: 800).frame(maxWidth: .infinity)
            .onChange(of: recording.notes) { _, value in draft.synchronize(value) }
            .onChange(of: store.unsavedIDs) { _, _ in draft.acknowledgeSave() }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("BungBungiWillSave"))) { _ in editor.endComposition(); draft.flush() }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("BungBungiFindNotes"))) { _ in editor.find() }
            .onDisappear { editor.endComposition(); draft.flush() }
    }
}
