import SwiftUI
import SoriCore

struct RecordingDetailView: View {
    @Bindable var store: AppStore
    let recording: Recording
    @State private var showAudioReview = false
    @State private var showLectureNotes = false
    @State private var editingSegment: SegmentEdit?
    @State private var editedText = ""
    @State private var titleDraft = ""
    @State private var renaming = false
    @State private var showSearch = false
    @State private var searchFocusRequested = false
    @State private var selectedSearchID: Int?
    @State private var textSize: Double = 22
    @State private var scrollRequest = 0
    @State private var searchScrollRequest = 0
    @FocusState private var searchFocused: Bool

    init(store: AppStore, recording: Recording, transcriptVisible: Bool = false, searchVisible: Bool = false) {
        self.store = store
        self.recording = recording
        _showLectureNotes = State(initialValue: recording.lectureHighlights != nil && !searchVisible && !transcriptVisible)
        _showSearch = State(initialValue: searchVisible)
    }

    private struct SegmentEdit: Identifiable {
        let id = UUID()
        let recordingID: UUID
        let segment: TranscriptSegment
    }

    private var activeID: Int? { Transcript.activeID(at: store.audio.currentTime, in: recording.segments) }
    private var query: String { store.transcriptSearch.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var matchingIDs: [Int] {
        guard !query.isEmpty else { return [] }
        return recording.segments.filter { displayedText($0).range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }.map(\.id)
    }
    private var searchPosition: Int {
        guard let selectedSearchID, let index = matchingIDs.firstIndex(of: selectedSearchID) else { return 0 }
        return index + 1
    }
    private var canPlay: Bool { store.audio.duration > 0 && !store.audio.isRecording }
    private var canEditTranscript: Bool { store.canModify(recording.id) }
    private var recordingDate: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(recording.createdAt) { return "오늘" }
        if calendar.isDateInYesterday(recording.createdAt) { return "어제" }
        let format = calendar.component(.year, from: recording.createdAt) == calendar.component(.year, from: Date())
            ? Date.FormatStyle.dateTime.month().day()
            : Date.FormatStyle.dateTime.year().month().day()
        return recording.createdAt.formatted(format.locale(Locale(identifier: "ko_KR")))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            tools
            if recording.work?.state == .interrupted {
                RecoveryBanner(store: store, recording: recording).padding(.horizontal, 34).padding(.bottom, 12)
            }
            if !recording.segments.isEmpty && (recording.status.isProcessing || store.queue.contains(recording.id) || store.isFinalizing(recording.id)) { progressBanner }
            if let message = recording.message { messageBanner(message) }
            if let ranges = recording.reviewRanges, !ranges.isEmpty { audioReviewBanner(ranges) }

            if recording.id == store.recordingID { recordingState }
            else if recording.segments.isEmpty { emptyTranscript }
            else if showLectureNotes {
                LectureNotesView(recording: recording,
                                 isProcessing: recording.status.isProcessing || store.queue.contains(recording.id),
                                 canGenerate: store.canOrganizeLecture(recording.id), canPlay: canPlay,
                                 generate: { store.enqueue(recording.id, lectureOnly: true) },
                                 play: { segment in
                                     showLectureNotes = false
                                     store.transcriptSearch = ""; showSearch = false
                                     store.followPlayback = true
                                     play(segment); scrollRequest += 1
                                 }, copied: { store.notify("핵심 요약을 복사했습니다") })
            }
            else { transcript }

            if store.showNotes {
                NotesView(store: store, recording: recording).id(recording.id).frame(height: 190)
            }
            if recording.id != store.recordingID { PlayerView(store: store, recording: recording) }
        }
        .sheet(item: $editingSegment) { edit in editor(edit) }
        .alert("강의 제목 수정", isPresented: $renaming) {
            TextField("강의 제목", text: $titleDraft)
            Button("취소", role: .cancel) {}
            Button("저장") {
                let title = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                store.renameRecording(recording.id, title: title)
            }.disabled(!store.canRename(recording.id) || titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || titleDraft.count > 120)
        }
        .onChange(of: recording.id) { _, _ in
            editingSegment = nil
            showAudioReview = false
            editedText = ""
            renaming = false
            titleDraft = ""
            showLectureNotes = recording.lectureHighlights != nil
            showSearch = false
            searchFocusRequested = false
            selectedSearchID = nil
            searchFocused = false
        }
        .onChange(of: matchingIDs, initial: true) { _, ids in
            if !ids.contains(selectedSearchID ?? -1) { selectedSearchID = ids.first }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("BungBungiFindTranscript"))) { _ in
            guard !recording.segments.isEmpty else { return }
            openSearch()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                HStack(spacing: 7) {
                    Image(systemName: "folder")
                    Text(store.currentProjectName).lineLimit(1).help(store.currentProjectName)
                }.font(.system(size: 13)).foregroundStyle(SoriTheme.secondary)
                Spacer(minLength: 12)
                Menu {
                    Button("텍스트 (.txt)") { store.export(recording, format: "txt") }
                    Button("자막 (.srt)") { store.export(recording, format: "srt") }
                    Button("전체 기록 (.json)") { store.export(recording, format: "json") }
                    Divider()
                    Button("전사문 복사") { store.copyTranscript() }
                } label: { Image(systemName: "square.and.arrow.up").font(.system(size: 16)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().padding(8).tint(SoriTheme.secondary).foregroundStyle(SoriTheme.secondary)
                    .disabled(recording.segments.isEmpty).help("내보내기").accessibilityLabel("전사문 내보내기")
                Menu {
                    Button("제목 수정") { titleDraft = recording.title; renaming = true }
                        .disabled(!store.canRename(recording.id))
                        .help("AI가 제목을 붙인 뒤 수정할 수 있어요")
                    Button(store.focusMode ? "보관함 보기" : "집중해서 읽기") { store.focusMode.toggle() }
                    Divider()
                    Toggle("원문 보기", isOn: $store.showOriginal).disabled(recording.segments.isEmpty)
                    Toggle("재생 중인 문장 따라가기", isOn: $store.followPlayback)
                    Menu("전사문 글자 크기") {
                        ForEach([Double(18), 22, 28], id: \.self) { size in
                            Button { textSize = size } label: {
                                Label(size == 18 ? "작게" : size == 22 ? "보통" : "크게", systemImage: textSize == size ? "checkmark" : "textformat.size")
                            }
                        }
                    }
                    Divider()
                    if !recording.status.isProcessing && recording.id != store.recordingID {
                        Button("다시 정리하기") { store.enqueue(recording.id) }.disabled(!store.canTranscribe(recording.id))
                    }
                    Divider()
                    RecordingMenu(store: store, recording: recording)
                } label: { Image(systemName: "ellipsis").font(.system(size: 17)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().padding(8).tint(SoriTheme.secondary).foregroundStyle(SoriTheme.secondary).help("녹음 관리").accessibilityLabel("녹음 관리")
            }
            HStack(alignment: .top, spacing: 12) {
                Text(recording.title).font(.system(size: 30, weight: .semibold)).tracking(-0.6).lineLimit(2).textSelection(.enabled)
                    .allowsTightening(false).fixedSize(horizontal: false, vertical: true).help(recording.title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if recording.generatedTitle != nil {
                    Button { titleDraft = recording.title; renaming = true } label: {
                        Image(systemName: "pencil").font(.system(size: 15)).frame(width: 30, height: 32)
                    }.buttonStyle(DetailControlStyle()).foregroundStyle(SoriTheme.secondary)
                        .disabled(!store.canRename(recording.id)).help("강의 제목 수정").accessibilityLabel("강의 제목 수정")
                }
            }
            HStack(spacing: 10) {
                Text(recordingDate)
                if recording.isDemo { Text("·"); Text("샘플 음성") }
                if recording.generatedTitle == nil && recording.status != .noSpeech && !recording.isDemo {
                    Text("·"); Text("AI가 제목을 붙인 뒤 수정할 수 있어요").lineLimit(1)
                }
                Spacer(minLength: 0)
                if store.showOriginal && !showLectureNotes { Text("원문").foregroundStyle(SoriTheme.accent) }
            }.font(.system(size: 13)).foregroundStyle(SoriTheme.secondary)
        }.padding(.horizontal, 38).padding(.top, 32).padding(.bottom, 24)
    }

    private var tools: some View {
        HStack(spacing: 12) {
            HStack(spacing: 22) {
                modeButton("핵심 요약", selected: showLectureNotes) { showLectureNotes = true; searchFocused = false }
                modeButton("전사문", selected: !showLectureNotes) { showLectureNotes = false }
            }
            Spacer(minLength: 4)
            if !showLectureNotes {
                Button { store.copyTranscript() } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 15)).frame(width: 32, height: 34)
                }.buttonStyle(DetailControlStyle()).foregroundStyle(SoriTheme.secondary)
                    .disabled(recording.segments.isEmpty).help("전사문 전체 복사").accessibilityLabel("전사문 전체 복사")
            }
            Button { openSearch() } label: { Image(systemName: "magnifyingglass").font(.system(size: 16)).frame(width: 32, height: 34).contentShape(Rectangle()) }
                .buttonStyle(DetailControlStyle()).foregroundStyle(showSearch || !query.isEmpty ? SoriTheme.ink : SoriTheme.secondary).keyboardShortcut("f", modifiers: .command)
                .help("전사문에서 찾기 · ⌘F").accessibilityLabel("전사문에서 찾기").disabled(recording.segments.isEmpty)
            Button { store.showNotes.toggle() } label: { Image(systemName: "note.text").font(.system(size: 16)).frame(width: 32, height: 34).contentShape(Rectangle()) }
                .buttonStyle(DetailControlStyle()).foregroundStyle(store.showNotes ? SoriTheme.ink : SoriTheme.secondary).help("메모와 북마크").accessibilityLabel(store.showNotes ? "메모와 북마크 닫기" : "메모와 북마크 열기")
        }.padding(.horizontal, 38)
            .background(alignment: .bottom) { Rectangle().fill(SoriTheme.line).frame(height: 1).padding(.horizontal, 38).allowsHitTesting(false) }
    }

    private func modeButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 14, weight: selected ? .semibold : .regular))
                .padding(.vertical, 13)
                .foregroundStyle(selected ? SoriTheme.ink : SoriTheme.secondary)
                .overlay(alignment: .bottom) { Rectangle().fill(selected ? SoriTheme.ink : .clear).frame(height: 2) }
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(SoriTheme.secondary).accessibilityHidden(true)
            TextField(store.showOriginal ? "원문에서 찾기" : "전사문에서 찾기", text: $store.transcriptSearch)
                .textFieldStyle(.plain).focused($searchFocused).onSubmit { moveSearch(by: 1) }
                .autocorrectionDisabled().layoutPriority(1)
                .onExitCommand { closeSearch() }
                .accessibilityLabel(store.showOriginal ? "원문 검색" : "전사문 검색")
            if !query.isEmpty {
                Text(matchingIDs.isEmpty ? "결과 없음" : "\(searchPosition) / \(matchingIDs.count)")
                    .font(.system(size: 13)).monospacedDigit().foregroundStyle(SoriTheme.secondary).fixedSize()
                    .accessibilityLabel(matchingIDs.isEmpty ? "일치하는 문장이 없습니다" : "일치하는 문장 \(matchingIDs.count)개 중 \(searchPosition)번째")
                Button { moveSearch(by: -1) } label: { Image(systemName: "chevron.up").frame(width: 28, height: 28).contentShape(Rectangle()) }
                    .keyboardShortcut("g", modifiers: [.command, .shift]).help("이전 결과 · ⇧⌘G").accessibilityLabel("이전 검색 결과")
                    .disabled(matchingIDs.isEmpty)
                Button { moveSearch(by: 1) } label: { Image(systemName: "chevron.down").frame(width: 28, height: 28).contentShape(Rectangle()) }
                    .keyboardShortcut("g", modifiers: .command).help("다음 결과 · ⌘G").accessibilityLabel("다음 검색 결과")
                    .disabled(matchingIDs.isEmpty)
            }
            Button { closeSearch() } label: { Image(systemName: "xmark").foregroundStyle(SoriTheme.secondary).frame(width: 28, height: 28).contentShape(Rectangle()) }
                .help("검색 닫기 · Esc").accessibilityLabel("검색 닫기")
        }.buttonStyle(.plain).font(.system(size: 14)).padding(.horizontal, 12).padding(.vertical, 8)
            .background(SoriTheme.surface, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(searchFocused ? SoriTheme.accent.opacity(0.35) : SoriTheme.line, lineWidth: 1))
            .padding(.horizontal, 38).padding(.top, 16).padding(.bottom, 4)
            .onAppear {
                if searchFocusRequested { searchFocused = true; searchFocusRequested = false }
            }
    }

    private var transcript: some View {
        VStack(spacing: 0) {
            if showSearch { searchBar }
            SelectableTranscriptView(
                recordingID: recording.id, segments: recording.segments,
                original: store.showOriginal, textSize: textSize, query: query,
                selectedSearchID: selectedSearchID, activeID: activeID, playbackTime: store.audio.currentTime,
                followPlayback: store.followPlayback, scrollRequest: scrollRequest,
                searchScrollRequest: searchScrollRequest, canPlay: canPlay, canEdit: canEditTranscript,
                play: play, togglePlayback: { store.audio.togglePlayback() }, isLooping: isLooping, isBookmarked: isBookmarked,
                edit: edit, repeatSegment: toggleLoop, bookmark: addBookmark, copy: copy)
        }
    }

    private func displayedText(_ segment: TranscriptSegment) -> String { store.showOriginal ? segment.originalText : segment.text }
    private func openSearch() {
        showLectureNotes = false
        if showSearch { searchFocused = true }
        else { searchFocusRequested = true; showSearch = true }
    }
    private func moveSearch(by offset: Int) {
        let ids = matchingIDs
        guard !ids.isEmpty else { return }
        let index = selectedSearchID.flatMap { ids.firstIndex(of: $0) } ?? (offset > 0 ? -1 : 0)
        selectedSearchID = ids[(index + offset + ids.count) % ids.count]
        searchScrollRequest += 1
    }
    private func closeSearch() {
        store.transcriptSearch = ""; selectedSearchID = nil; showSearch = false; searchFocused = false; searchFocusRequested = false
    }
    private func seek(_ time: Double) {
        if let loop = store.audio.loopRange, time < loop.lowerBound || time >= loop.upperBound { store.audio.clearLoop() }
        store.audio.seek(time)
    }
    private func play(_ segment: TranscriptSegment) {
        guard canPlay else { return }
        if store.audio.loopRange != nil && !isLooping(segment) { store.audio.clearLoop() }
        seek(segment.start)
        scrollRequest += 1
        if !store.audio.isPlaying { store.audio.togglePlayback() }
    }
    private func isLooping(_ segment: TranscriptSegment) -> Bool {
        guard let range = store.audio.loopRange else { return false }
        return abs(range.lowerBound - segment.start) < 0.05 && abs(range.upperBound - min(segment.end, store.audio.duration)) < 0.05
    }
    private func toggleLoop(_ segment: TranscriptSegment) {
        guard canPlay else { return }
        if isLooping(segment) { store.audio.clearLoop() }
        else {
            store.audio.setLoop(start: segment.start, end: segment.end)
            store.audio.seek(segment.start)
            if !store.audio.isPlaying { store.audio.togglePlayback() }
        }
    }
    private func edit(_ segment: TranscriptSegment) {
        editedText = segment.text
        editingSegment = SegmentEdit(recordingID: recording.id, segment: segment)
    }
    private func copy(_ segment: TranscriptSegment) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(displayedText(segment), forType: .string)
        store.notify("문장을 복사했습니다")
    }
    private func isBookmarked(_ segment: TranscriptSegment) -> Bool {
        recording.bookmarks.contains { abs($0.time - segment.start) < 0.1 }
    }
    private func addBookmark(_ segment: TranscriptSegment) {
        guard !isBookmarked(segment) else { store.showNotes = true; return }
        let saved = store.update(recording.id) {
            $0.bookmarks.append(.init(time: segment.start, label: String(segment.text.prefix(60))))
            $0.bookmarks.sort { $0.time < $1.time }
        }
        if saved { store.notify("북마크를 추가했습니다") }
    }

    private func editor(_ edit: SegmentEdit) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("문장 수정").font(.system(size: 22, weight: .semibold))
                    Text("\(TimeText.clock(edit.segment.start)) – \(TimeText.clock(edit.segment.end)) · 시간과 원문은 유지됩니다")
                        .font(.system(size: 13)).foregroundStyle(SoriTheme.secondary)
                }
                Spacer()
                Button { play(edit.segment) } label: { Label("다시 듣기", systemImage: "play.circle") }
                    .buttonStyle(.bordered).disabled(!canPlay)
            }
            TextEditor(text: $editedText).font(.system(size: 16)).lineSpacing(6).scrollContentBackground(.hidden)
                .padding(12).background(SoriTheme.paper, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(SoriTheme.line, lineWidth: 1)).frame(height: 165)
                .accessibilityLabel("수정할 문장")
            DisclosureGroup("수정 전 원문") {
                Text(edit.segment.originalText).font(.system(size: 14)).foregroundStyle(SoriTheme.secondary)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
            }.font(.system(size: 13))
            HStack {
                Button("원문으로 되돌리기") { editedText = edit.segment.originalText }.disabled(editedText == edit.segment.originalText)
                Spacer()
                Button("취소") { editingSegment = nil }.keyboardShortcut(.cancelAction)
                Button("저장") {
                    let text = editedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let saved = store.update(edit.recordingID) { item in
                        if let index = item.segments.firstIndex(where: { $0.id == edit.segment.id }), item.segments[index].text != text {
                            item.segments[index].text = text
                            // Notes must be regenerated from the edited text before displaying quotes.
                            item.lectureHighlights = nil
                        }
                    }
                    if saved {
                        store.showOriginal = false
                        editingSegment = nil
                        store.notify("문장을 저장했습니다")
                    }
                }.keyboardShortcut(.return, modifiers: .command).buttonStyle(.borderedProminent).tint(SoriTheme.accent)
                    .disabled(editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !canEditTranscript)
            }
        }.padding(28).frame(width: 530).background(SoriTheme.surface)
    }

    private var progressBanner: some View {
        ProcessingProgressView(store: store, recordingID: recording.id, compact: true)
            .padding(.horizontal, 34).padding(.bottom, 10)
    }

    private func audioReviewBanner(_ ranges: [AudioReviewRange]) -> some View {
        HStack(spacing: 12) {
            Text("텍스트에 빠진 말이 있을 수 있어요.")
            Spacer(minLength: 0)
            Button("음성 확인") { showAudioReview = true }
                .fixedSize().disabled(!canPlay)
                .popover(isPresented: $showAudioReview, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("확인이 필요한 음성").font(.headline)
                        Text("녹음과 전사문을 확인한 구간은 완료로 표시하세요.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        ScrollView {
                            VStack(spacing: 12) {
                                ForEach(Array(ranges.enumerated()), id: \.offset) { _, range in
                                    HStack(spacing: 18) {
                                        Button("\(TimeText.clock(range.start))–\(TimeText.clock(range.end)) 듣기") {
                                            showLectureNotes = false
                                            store.audio.seek(range.start)
                                            if !store.audio.isPlaying { store.audio.togglePlayback() }
                                            scrollRequest += 1
                                        }.buttonStyle(.plain)
                                        Spacer()
                                        Button("확인 완료") {
                                            store.update(recording.id) {
                                                $0.reviewRanges?.removeAll { $0 == range }
                                                $0.status = $0.completedStatus
                                            }
                                            if ranges.count == 1 { showAudioReview = false }
                                        }.disabled(!canEditTranscript)
                                    }
                                }
                            }.padding(.vertical, 4)
                        }.frame(maxHeight: 260)
                    }.padding(20).frame(width: 390)
                }
        }
        .font(.system(size: 13)).foregroundStyle(SoriTheme.secondary)
        .padding(12).background(SoriTheme.accentSoft.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 34).padding(.bottom, 10)
    }

    private func messageBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "info.circle").padding(.top, 2).accessibilityHidden(true)
            Text(message).lineLimit(3).help(message)
            Spacer(minLength: 0)
            Button { store.update(recording.id) { $0.message = nil } } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).accessibilityLabel("알림 닫기")
        }.font(.system(size: 13)).foregroundStyle(SoriTheme.secondary).padding(12).background(SoriTheme.accentSoft.opacity(0.6), in: RoundedRectangle(cornerRadius: 8)).padding(.horizontal, 34).padding(.bottom, 10)
    }

    private var emptyTranscript: some View {
        let waiting = store.queue.contains(recording.id)
        return VStack(spacing: 18) {
            Spacer()
            if recording.status.isProcessing || waiting || store.isFinalizing(recording.id) {
                ProcessingProgressView(store: store, recordingID: recording.id)
                    .padding(.horizontal, 30)
            } else if recording.work?.state == .interrupted {
                Image(systemName: "waveform").font(.system(size: 36, weight: .ultraLight)).foregroundStyle(SoriTheme.secondary)
                Text(recording.work?.kind == .recording ? "저장된 음성을 다시 들을 수 있어요" : "교정이 끝나면 전사문을 보여드립니다")
                    .font(.system(size: 18, weight: .medium))
                Text("녹음 파일은 보관되어 있습니다.")
                    .font(.system(size: 14)).foregroundStyle(SoriTheme.secondary).multilineTextAlignment(.center)
            } else if recording.status == .noSpeech {
                Text("감지된 음성이 없어요")
                    .font(.system(size: 20, weight: .medium)).multilineTextAlignment(.center)
                Text("녹음 파일은 저장되어 있어요. 재생해서 확인할 수 있습니다.")
                    .font(.system(size: 14)).foregroundStyle(SoriTheme.secondary).multilineTextAlignment(.center).lineSpacing(7)
                if store.settings.transcriptionReady {
                    Button("다시 시도") { store.enqueue(recording.id) }
                        .font(.system(size: 14)).buttonStyle(.plain).foregroundStyle(SoriTheme.secondary).padding(.top, 7)
                        .disabled(!store.canTranscribe(recording.id))
                } else {
                    Button("AI 설정") { NotificationCenter.default.post(name: Notification.Name("BungBungiShowSettings"), object: nil) }
                        .font(.system(size: 14)).buttonStyle(.plain).foregroundStyle(SoriTheme.secondary).padding(.top, 7)
                }
            } else {
                Image(systemName: "text.bubble").font(.system(size: 42, weight: .ultraLight)).foregroundStyle(SoriTheme.accent.opacity(0.8))
                Text("아직 정리된 내용이 없습니다").font(.system(size: 22, weight: .medium))
                Text(store.settings.transcriptionReady ? "AI가 녹음을 정리해 드려요." : store.settings.transcriptionUnavailableReason)
                    .font(.system(size: 14)).foregroundStyle(SoriTheme.secondary).multilineTextAlignment(.center).lineSpacing(7)
                if store.settings.transcriptionReady {
                    Button("AI 정리 시작") { store.enqueue(recording.id) }.buttonStyle(PrimaryButtonStyle()).padding(.top, 7).disabled(!store.canTranscribe(recording.id))
                } else {
                    Button("AI 설정") { NotificationCenter.default.post(name: Notification.Name("BungBungiShowSettings"), object: nil) }
                        .buttonStyle(.bordered).padding(.top, 7)
                }
            }
            Spacer()
        }.frame(maxWidth: .infinity).padding(.horizontal, 28)
    }

    private var recordingState: some View {
        let interrupted = recording.work?.state == .interrupted
        return VStack(spacing: interrupted ? 16 : 24) {
            Spacer()
            if !interrupted {
            Text(store.audio.isPausedRecording ? "녹음 일시 정지" : "녹음 중")
                .font(.system(size: 22, weight: .medium))
            }
            Text(TimeText.clock(store.audio.recordingTime)).font(.system(size: interrupted ? 52 : 64, weight: .light)).monospacedDigit().tracking(-2)
                .accessibilityLabel("녹음 시간 \(TimeText.clock(store.audio.recordingTime))")
            WaveformView(samples: store.audio.liveLevels, live: true).frame(height: interrupted ? 48 : 90).padding(.horizontal, 55)
            HStack(spacing: 18) {
                Button { store.toggleRecordingPause() } label: { Label(store.audio.isPausedRecording ? "계속 녹음" : "일시 정지", systemImage: store.audio.isPausedRecording ? "mic.fill" : "pause.fill") }.buttonStyle(.bordered)
                    .disabled(store.isSleeping || store.isPreparingForSleep)
                Button { Task { await store.stopRecording() } } label: { Label("녹음 마치기", systemImage: "stop.fill") }.buttonStyle(PrimaryButtonStyle())
            }
            Text(store.settings.transcriptionReady ? "녹음을 마치면 AI가 정리해 드려요." : "녹음을 마치면 음성 파일이 작업 폴더에 저장됩니다.")
                .font(.system(size: 14)).foregroundStyle(SoriTheme.secondary)
            Spacer()
        }.frame(maxWidth: .infinity)
    }
}

struct PlayerView: View {
    @Bindable var store: AppStore
    let recording: Recording
    @State private var isScrubbing = false
    @State private var scrubTime: Double = 0
    @FocusState private var playerFocused: Bool
    private var displayedTime: Double { isScrubbing ? scrubTime : store.audio.currentTime }
    private var progress: Double { store.audio.duration > 0 ? displayedTime / store.audio.duration : 0 }
    private var playable: Bool { store.audio.duration > 0 && !store.audio.isRecording }
    private var isBookmarked: Bool { recording.bookmarks.contains { abs($0.time - store.audio.currentTime) < 0.1 } }

    var body: some View {
        VStack(spacing: 12) {
            Rectangle().fill(SoriTheme.line).frame(height: 1)
            if store.audio.loopRange != nil {
                HStack(spacing: 7) {
                    Image(systemName: "repeat.1")
                    Text("문장 반복 중").fontWeight(.medium)
                    Spacer()
                    Button("해제") { store.audio.clearLoop() }.buttonStyle(.plain).accessibilityLabel("문장 반복 해제")
                }.font(.system(size: 13)).foregroundStyle(SoriTheme.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 8).background(SoriTheme.accentSoft, in: RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 9) {
                Text(TimeText.clock(displayedTime)).font(.system(size: 14)).monospacedDigit().foregroundStyle(SoriTheme.ink).frame(minWidth: 48)
                GeometryReader { geometry in
                    ZStack {
                        WaveformView(samples: recording.waveform, progress: progress)
                        if let range = store.audio.loopRange, store.audio.duration > 0 {
                            RoundedRectangle(cornerRadius: 3).fill(SoriTheme.accent.opacity(0.12))
                                .frame(width: max(3, (range.upperBound - range.lowerBound) / store.audio.duration * geometry.size.width))
                                .position(x: (range.lowerBound + range.upperBound) / 2 / store.audio.duration * geometry.size.width, y: geometry.size.height / 2)
                        }
                        Capsule().fill(SoriTheme.accent).frame(width: 2, height: 28)
                            .position(x: min(max(0, progress), 1) * geometry.size.width, y: geometry.size.height / 2)
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        isScrubbing = true
                        scrubTime = min(max(0, value.location.x / max(1, geometry.size.width) * store.audio.duration), store.audio.duration)
                    }.onEnded { _ in
                        seek(scrubTime); isScrubbing = false; playerFocused = true
                    })
                    .accessibilityElement(children: .ignore).accessibilityLabel("재생 위치")
                    .accessibilityValue("\(TimeText.clock(displayedTime)), 전체 \(TimeText.clock(store.audio.duration))")
                    .accessibilityAdjustableAction { direction in seek(store.audio.currentTime + (direction == .increment ? 5 : -5)) }
                    .help("클릭하거나 드래그하여 재생 위치 이동")
                }.frame(height: 34)
                Text(TimeText.clock(store.audio.duration))
                    .font(.system(size: 14)).monospacedDigit().foregroundStyle(SoriTheme.secondary).frame(minWidth: 48)
                    .accessibilityLabel("전체 시간 \(TimeText.clock(store.audio.duration))")
            }.padding(.top, 3)
            HStack {
                Menu {
                    ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { rate in
                        Button { store.audio.rate = rate } label: { Label("\(rate.formatted())×", systemImage: store.audio.rate == rate ? "checkmark" : "speedometer") }
                    }
                } label: { Text(store.audio.rate == 1 ? "속도" : "\(store.audio.rate.formatted())배").font(.system(size: 14)).frame(width: 48) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().tint(SoriTheme.secondary).help("재생 속도").accessibilityLabel("재생 속도 \(store.audio.rate.formatted())배")
                Spacer()
                HStack(spacing: 25) {
                    Button { seek(store.audio.currentTime - 10) } label: { Image(systemName: "gobackward.10").font(.system(size: 21, weight: .light)).frame(width: 36, height: 36) }
                        .buttonStyle(DetailControlStyle()).help("10초 뒤로 · ⌘←").accessibilityLabel("10초 뒤로")
                    Button { store.audio.togglePlayback(); playerFocused = true } label: {
                        Image(systemName: store.audio.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 24)).offset(x: store.audio.isPlaying ? 0 : 1)
                            .foregroundStyle(SoriTheme.ink).frame(width: 46, height: 46)
                    }.buttonStyle(DetailControlStyle()).help("재생 / 일시 정지 · ⇧⌘P").accessibilityLabel(store.audio.isPlaying ? "일시 정지" : "재생")
                    Button { seek(store.audio.currentTime + 10) } label: { Image(systemName: "goforward.10").font(.system(size: 21, weight: .light)).frame(width: 36, height: 36) }
                        .buttonStyle(DetailControlStyle()).help("10초 앞으로 · ⌘→").accessibilityLabel("10초 앞으로")
                }
                Spacer()
                Button { store.bookmark() } label: { Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark").font(.system(size: 16)).frame(width: 48, height: 36) }
                    .buttonStyle(DetailControlStyle()).help(isBookmarked ? "이 위치에 북마크가 있습니다" : "현재 위치에 북마크 · ⌘B")
                    .accessibilityLabel(isBookmarked ? "현재 위치에 북마크가 있습니다" : "현재 위치에 북마크 추가")
            }.padding(.horizontal, 14)
            if !playable {
                Text("오디오 파일을 확인해 주세요").font(.system(size: 13)).foregroundStyle(SoriTheme.secondary)
            }
        }.padding(.horizontal, 30).padding(.bottom, 20).background(SoriTheme.paper)
            .disabled(!playable)
            .focusable().focused($playerFocused)
            .onKeyPress(.space) {
                guard playable else { return .ignored }
                store.audio.togglePlayback(); return .handled
            }
            .onChange(of: recording.id) { _, _ in isScrubbing = false; scrubTime = 0; playerFocused = false }
    }
    private func seek(_ time: Double) {
        if let loop = store.audio.loopRange, time < loop.lowerBound || time >= loop.upperBound { store.audio.clearLoop() }
        store.audio.seek(time)
    }
}

private struct DetailControlStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .background(isEnabled && (hovered || configuration.isPressed) ? SoriTheme.sidebar : .clear, in: RoundedRectangle(cornerRadius: 6))
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovered = $0 }
    }
}

struct NotesView: View {
    @Bindable var store: AppStore
    let recording: Recording
    @State private var draft = ""
    @State private var savedDraft = ""
    @State private var draftOwner: UUID?
    @State private var saveTask: Task<Void, Never>?
    @FocusState private var notesFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("메모").font(.system(size: 14, weight: .medium))
                    Spacer()
                    if store.unsavedIDs.contains(recording.id) || draft != savedDraft {
                        Text(store.unsavedIDs.contains(recording.id) ? "저장 실패" : "저장 중…")
                            .font(.system(size: 13)).foregroundStyle(store.unsavedIDs.contains(recording.id) ? SoriTheme.recording : SoriTheme.secondary)
                    }
                }
                ZStack(alignment: .topLeading) {
                    if draft.isEmpty { Text("메모를 남겨보세요").font(.system(size: 14)).foregroundStyle(SoriTheme.secondary).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false).accessibilityHidden(true) }
                    TextEditor(text: $draft).font(.system(size: 14)).lineSpacing(5).scrollContentBackground(.hidden)
                        .focused($notesFocused).accessibilityLabel("이 녹음의 메모")
                }.frame(minHeight: 112, maxHeight: .infinity, alignment: .topLeading)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(notesFocused ? SoriTheme.secondary.opacity(0.35) : .clear, lineWidth: 1).allowsHitTesting(false))
            }.frame(maxWidth: .infinity)
            Rectangle().fill(SoriTheme.line).frame(width: 1)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("북마크").font(.system(size: 14, weight: .medium))
                    Spacer()
                    Button { store.bookmark() } label: { Image(systemName: "plus").font(.system(size: 14)) }
                        .buttonStyle(.plain).help("현재 위치에 북마크 · ⌘B").accessibilityLabel("현재 위치에 북마크 추가")
                        .disabled(store.audio.duration == 0 || store.audio.isRecording)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if recording.bookmarks.isEmpty {
                            Text("다시 듣고 싶은 곳에 북마크를 남기세요.")
                                .font(.system(size: 14)).foregroundStyle(SoriTheme.secondary).lineSpacing(5).fixedSize(horizontal: false, vertical: true).padding(.top, 7)
                        }
                        ForEach(recording.bookmarks) { bookmark in
                            HStack(alignment: .top) {
                                Button {
                                    if let loop = store.audio.loopRange, !loop.contains(bookmark.time) { store.audio.clearLoop() }
                                    store.audio.seek(bookmark.time)
                                    if !store.audio.isPlaying { store.audio.togglePlayback() }
                                } label: {
                                    HStack(alignment: .top, spacing: 7) {
                                        Text(TimeText.clock(bookmark.time)).font(.system(size: 13)).monospacedDigit().foregroundStyle(SoriTheme.secondary).fixedSize()
                                        Text(bookmark.label).font(.system(size: 14)).lineLimit(2).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                                    }
                                }.buttonStyle(.plain).help(bookmark.label).disabled(store.audio.duration == 0 || store.audio.isRecording)
                                    .accessibilityLabel("\(TimeText.clock(bookmark.time)) 북마크 재생, \(bookmark.label)")
                                Spacer(minLength: 0)
                                Button { store.update(recording.id) { $0.bookmarks.removeAll { $0.id == bookmark.id } } } label: {
                                    Image(systemName: "xmark").font(.system(size: 12)).foregroundStyle(SoriTheme.secondary).padding(5)
                                }.buttonStyle(.plain).help("북마크 삭제").accessibilityLabel("\(TimeText.clock(bookmark.time)) 북마크 삭제")
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.frame(maxWidth: .infinity)
        }.padding(20).background(SoriTheme.surface)
            .overlay(alignment: .top) { Rectangle().fill(SoriTheme.line).frame(height: 1).allowsHitTesting(false) }
            .onAppear { loadDraft() }
            .onChange(of: draft) { _, _ in scheduleSave() }
            .onChange(of: recording.id) { _, _ in flush(); loadDraft() }
            .onChange(of: recording.notes) { _, value in
                // Preserve a local edit if another part of the recording updates while typing.
                if draft == savedDraft && value != savedDraft { savedDraft = value; draft = value }
            }
            .onChange(of: store.unsavedIDs) { _, ids in
                if !ids.contains(recording.id), recording.notes == draft { savedDraft = draft }
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("BungBungiWillSave"))) { _ in flush() }
            .onDisappear { flush() }
    }

    private func loadDraft() {
        saveTask?.cancel()
        draftOwner = recording.id
        savedDraft = recording.notes
        draft = recording.notes
    }
    private func scheduleSave() {
        saveTask?.cancel()
        guard let id = draftOwner, draft != savedDraft else { return }
        let value = draft
        saveTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard !Task.isCancelled, draftOwner == id, draft == value else { return }
            if store.update(id, { $0.notes = value }) { savedDraft = value }
        }
    }
    private func flush() {
        saveTask?.cancel()
        guard let id = draftOwner, draft != savedDraft else { return }
        let value = draft
        if store.update(id, { $0.notes = value }) { savedDraft = value }
    }
}
