import SwiftUI
import SoriCore

struct ContentView: View {
    @Bindable var store: AppStore
    var transcriptVisible = false
    var searchVisible = false
    @State private var dropTarget = false

    var body: some View {
        GeometryReader { geometry in
            if let id = store.recordingID, let recording = store.recordings.first(where: { $0.id == id }) {
                RecordingWorkspaceView(store: store, recording: recording).id(id)
            } else {
                HStack(spacing: 0) {
                    if !store.focusMode {
                        SidebarView(store: store).frame(width: geometry.size.width > 1150 ? 280 : 250)
                        Rectangle().fill(SoriTheme.line).frame(width: 1)
                    }
                    Group {
                        if let selected = store.selected { RecordingDetailView(store: store, recording: selected, transcriptVisible: transcriptVisible, searchVisible: searchVisible) }
                        else { WelcomeView(store: store) }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(SoriTheme.paper)
        .foregroundStyle(SoriTheme.ink)
        // Keep keyboard focus without the system-accent halo on clicked regions.
        .focusEffectDisabled()
        .sheet(isPresented: Binding(get: { store.settings.showConnectionSetup }, set: { store.settings.showConnectionSetup = $0 }), onDismiss: store.connectionSetupDismissed) { AIConnectionSetupView(store: store) }
        .sheet(isPresented: $store.showRecordingDestination) { RecordingDestinationView(store: store) }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("BungBungiFindLibrary"))) { _ in
            store.focusMode = false
            store.librarySearchRequested = true
        }
        .overlay(alignment: .bottom) {
            if let toast = store.toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(SoriTheme.ink, in: Capsule()).padding(.bottom, 25)
                    .allowsHitTesting(false)
                    .accessibilityLabel(toast)
            }
        }
        .overlay {
            if dropTarget {
                ZStack {
                    SoriTheme.paper.opacity(0.94)
                    RoundedRectangle(cornerRadius: 15)
                        .strokeBorder(SoriTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [8])).padding(12)
                    VStack(spacing: 14) {
                        Image(systemName: "square.and.arrow.down").font(.system(size: 36, weight: .light))
                        Text("여기에 파일을 놓으세요").font(.system(size: 22, weight: .semibold))
                        Text("오디오와 동영상의 음성을 작업 폴더에 가져옵니다")
                            .font(.system(size: 13)).foregroundStyle(SoriTheme.secondary)
                    }.foregroundStyle(SoriTheme.accent)
                }.allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard store.recordingID == nil, !store.isImporting, !urls.isEmpty else { return false }
            guard urls.allSatisfy(AppStore.canImport) else {
                store.errorMessage = "오디오 또는 동영상 파일만 가져올 수 있습니다. 폴더와 웹 주소는 지원하지 않습니다."
                return false
            }
            Task { await store.importFiles(urls) }
            return true
        } isTargeted: { dropTarget = $0 && !store.isImporting && store.recordingID == nil }
        .alert("작업을 완료하지 못했습니다", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("확인") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }
}

struct SidebarView: View {
    @Bindable var store: AppStore
    @State private var showNewFolder = false
    @State private var folderName = ""
    @State private var renaming: Project?
    @State private var hoveredProject: UUID?
    @State private var expandedProjects: Set<UUID> = []
    @State private var dropProjectID: UUID?
    @AppStorage("librarySort") private var sort = LibrarySort.newest
    @State private var filter = LibraryFilter.all
    @FocusState private var focusedProject: UUID?
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    private var query: String { store.search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var items: [Recording] { ordered(store.visibleRecordings) }

    private func ordered(_ recordings: [Recording]) -> [Recording] {
        recordings.filter { filter.includes($0, queued: store.queue.contains($0.id)) }.sorted {
            switch sort {
            case .newest: $0.createdAt > $1.createdAt
            case .oldest: $0.createdAt < $1.createdAt
            case .title: $0.title.localizedStandardCompare($1.title) == .orderedAscending
            case .longest: $0.duration == $1.duration ? $0.createdAt > $1.createdAt : $0.duration > $1.duration
            }
        }
    }

    private var recordingDestination: String {
        store.projects.first { $0.id == store.selectedProjectID }?.name ?? store.projects.first?.name ?? "작업 폴더"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                BrandMark(size: 24)
                Text("둥둥이").font(.system(size: 18, weight: .semibold))
                Spacer()
            }.padding(.top, 48).padding(.horizontal, 22)

            Button {
                if store.audio.isRecording { Task { await store.stopRecording() } }
                else { store.requestRecording() }
            } label: {
                Label(store.audio.isRecording ? "녹음 마치기" : (store.isFinalizingRecording ? "저장 중…" : "강의 기록하기"),
                      systemImage: store.audio.isRecording ? "stop.fill" : "plus")
                    .font(.system(size: 14, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 6)
            }.buttonStyle(.borderedProminent).controlSize(.large).tint(store.audio.isRecording ? SoriTheme.recording : SoriTheme.ink)
                .disabled(store.isStartingRecording || store.isFinalizingRecording || store.repository == nil)
                .help(store.audio.isRecording ? "녹음 마치기 · ⌘R" : "녹음부터 전사문과 핵심 요약까지 · ⌘R")
                .padding(.horizontal, 18).padding(.top, 26)

            if !store.audio.isRecording && !store.isFinalizingRecording {
                HStack(spacing: 4) {
                    Button { store.requestRecording(mode: .audioOnly) } label: {
                        Label("녹음하기", systemImage: "waveform")
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 6).padding(.vertical, 10).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(SoriTheme.secondary)
                        .disabled(store.isStartingRecording || store.repository == nil)
                        .help("음성만 저장하고, 필요할 때 정리 · ⌥⌘R")
                    RecordingModeHelp()
                }.frame(maxWidth: .infinity).padding(.horizontal, 18).padding(.top, 4)
            }

            librarySearch.padding(.horizontal, 18).padding(.top, 17).padding(.bottom, 10)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if !query.isEmpty {
                            Text("검색 결과").font(.system(size: 12)).foregroundStyle(SoriTheme.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 11).padding(.vertical, 9)
                            searchResults(items)
                        } else {
                            HStack {
                                Text("폴더").font(.system(size: 13)).foregroundStyle(SoriTheme.secondary)
                                Spacer()
                                Button { folderName = ""; showNewFolder = true } label: { Image(systemName: "plus").font(.system(size: 14)) }
                                    .buttonStyle(QuietButtonStyle()).help("새 작업 폴더 만들기").accessibilityLabel("새 작업 폴더 만들기")
                                    .disabled(store.repository == nil)
                            }.padding(.leading, 11).padding(.trailing, 4).padding(.top, 4).padding(.bottom, 4)
                            ForEach(store.projects) { project in projectBranch(project) }
                        }
                    }.padding(.horizontal, 12).padding(.bottom, 12)
                }.frame(minHeight: 60)
                    .focusable().focused($listFocused).focusEffectDisabled()
                    .onMoveCommand { direction in
                        guard direction == .up || direction == .down, !items.isEmpty else { return }
                        let index = items.firstIndex { $0.id == store.selectedID }
                        let next = min(items.count - 1, max(0, (index ?? (direction == .down ? -1 : items.count)) + (direction == .down ? 1 : -1)))
                        store.select(items[next].id)
                        if query.isEmpty { expandedProjects.insert(items[next].projectID) }
                        let prefix = query.isEmpty ? "folder-" : "search-"
                        proxy.scrollTo(prefix + items[next].id.uuidString)
                    }
            }

            if store.audio.isRecording {
                VStack(alignment: .leading, spacing: 12) {
                    Divider()
                    HStack {
                        Text(store.audio.isPausedRecording ? "녹음 일시 정지" : "녹음 중").font(.system(size: 14, weight: .medium))
                        Spacer()
                        Text(TimeText.clock(store.audio.recordingTime)).font(.system(size: 14)).monospacedDigit()
                    }
                    WaveformView(samples: store.audio.liveLevels, live: true).frame(height: 28)
                    Button { store.toggleRecordingPause() } label: {
                        Label(store.audio.isPausedRecording ? "녹음 이어가기" : "일시 정지", systemImage: store.audio.isPausedRecording ? "mic.fill" : "pause.fill")
                            .font(.system(size: 14))
                    }.buttonStyle(.plain)
                }.padding(.horizontal, 20).padding(.top, 16)
            }

            VStack(alignment: .leading, spacing: 18) {
                Button { store.importAudio() } label: {
                    Label(store.isImporting ? "가져오는 중…" : "파일 가져오기", systemImage: "square.and.arrow.down")
                }.disabled(store.isImporting || store.repository == nil).help("오디오·동영상 파일 가져오기 · ⌘O")
                Button { NotificationCenter.default.post(name: Notification.Name("BungBungiShowSettings"), object: nil) } label: {
                    Label("설정", systemImage: "gearshape")
                }.help("설정 열기 · ⌘,")
            }.font(.system(size: 14)).buttonStyle(.plain).foregroundStyle(SoriTheme.secondary)
                .padding(.horizontal, 23).padding(.vertical, 24)

            SidebarAIStatusView(settings: store.settings)
        }
        .background(SoriTheme.sidebar)
        .onChange(of: store.selectedProjectID, initial: true) { _, id in
            if let id { expandedProjects.insert(id) }
            filter = .all
        }
        .onChange(of: store.librarySearchRequested, initial: true) { _, requested in
            if requested { searchFocused = true; store.librarySearchRequested = false }
        }
        .alert("새 작업 폴더", isPresented: $showNewFolder) {
            TextField("폴더 이름", text: $folderName)
            Button("취소", role: .cancel) {}
            Button("만들기") { store.createProject(folderName) }
                .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: { Text("녹음과 전사문을 작업별로 보관합니다.") }
        .alert("폴더 이름 변경", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("폴더 이름", text: $folderName)
            Button("취소", role: .cancel) { renaming = nil }
            Button("변경") { if let renaming { store.renameProject(renaming, name: folderName) }; renaming = nil }
                .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var librarySearch: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(SoriTheme.secondary)
            TextField("검색", text: $store.search).textFieldStyle(.plain).focused($searchFocused)
                .accessibilityLabel("폴더 전체에서 제목, 전사문, 필기 검색")
                .onSubmit { if let first = items.first { store.select(first.id); searchFocused = false; listFocused = true } }
            if !store.search.isEmpty {
                Button { store.search = ""; searchFocused = true } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(SoriTheme.secondary).help("검색 지우기")
            }
            Menu {
                Picker("정렬", selection: $sort) { ForEach(LibrarySort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                Divider()
                Picker("상태", selection: $filter) { ForEach(LibraryFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            } label: {
                Image(systemName: filter == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                    .frame(width: 20, height: 22)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("정렬 및 상태 필터 · \(sort.rawValue), \(filter.rawValue)").accessibilityLabel("녹음 정렬 및 상태 필터")
        }.font(.system(size: 13)).foregroundStyle(SoriTheme.secondary)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(SoriTheme.line.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
            .help("제목, 전사문, 필기 검색 · ⇧⌘F")
            .onExitCommand { store.search = ""; searchFocused = false }
    }

    private func searchResults(_ recordings: [Recording]) -> some View {
        VStack(spacing: 2) {
            if recordings.isEmpty {
                Text("검색 결과가 없습니다")
                    .font(.system(size: 13)).foregroundStyle(SoriTheme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 32).padding(.vertical, 12)
            }
            ForEach(recordings) { recording in
                RecordingRow(store: store, recording: recording, selected: store.selectedID == recording.id,
                             folder: store.projects.first { $0.id == recording.projectID }?.name, query: query)
                    .id("search-" + recording.id.uuidString)
            }
        }
    }

    private func projectBranch(_ project: Project) -> some View {
        VStack(spacing: 2) {
            projectRow(project) {
                if store.selectedProjectID == project.id && expandedProjects.contains(project.id) {
                    expandedProjects.remove(project.id)
                } else {
                    expandedProjects.insert(project.id)
                    store.selectProject(project.id)
                }
            }.contextMenu { projectMenu(project) }
            if expandedProjects.contains(project.id) {
                let items = ordered(store.recordings.filter { $0.projectID == project.id })
                if items.isEmpty {
                    Text(filter == .all ? "아직 녹음이 없어요" : "해당 상태의 녹음이 없어요").font(.system(size: 13)).foregroundStyle(SoriTheme.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 43).padding(.vertical, 9)
                } else {
                    ForEach(items) { recording in
                        RecordingRow(store: store, recording: recording, selected: store.selectedID == recording.id,
                                     folder: project.name, query: "")
                            .padding(.leading, 29).id("folder-" + recording.id.uuidString)
                    }
                }
            }
        }
        .dropDestination(for: RecordingTransfer.self) { references, _ in
            let moved = store.moveRecordings(references, to: project)
            if moved { expandedProjects.insert(project.id) }
            return moved
        } isTargeted: { targeted in
            if targeted { dropProjectID = project.id; expandedProjects.insert(project.id) }
            else if dropProjectID == project.id { dropProjectID = nil }
        }
    }

    private func projectRow(_ project: Project, action: @escaping () -> Void) -> some View {
        let selected = store.selectedProjectID == project.id
        return HStack(spacing: 0) {
            Button {
                if expandedProjects.contains(project.id) { expandedProjects.remove(project.id) }
                else { expandedProjects.insert(project.id) }
            } label: {
                Image(systemName: expandedProjects.contains(project.id) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 12, weight: .medium)).frame(width: 22, height: 30)
            }.buttonStyle(.plain).foregroundStyle(SoriTheme.secondary)
                .accessibilityLabel("\(project.name) \(expandedProjects.contains(project.id) ? "접기" : "펼치기")")
            Button(action: action) {
                HStack(spacing: 10) {
                    Image(systemName: expandedProjects.contains(project.id) ? "folder.fill" : "folder")
                        .font(.system(size: 14)).frame(width: 17).fixedSize()
                    Text(project.name).font(.system(size: 14, weight: selected ? .medium : .regular)).lineLimit(1)
                    Spacer(minLength: 4)
                }.padding(.leading, 1).padding(.trailing, 5).padding(.vertical, 9)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(project.name)
                .accessibilityAddTraits(selected ? [.isSelected] : []).help(project.name)
                .focused($focusedProject, equals: project.id).focusEffectDisabled()
            Menu { projectMenu(project) } label: {
                Image(systemName: "ellipsis").font(.system(size: 14)).frame(width: 24, height: 24)
            }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().tint(SoriTheme.secondary)
                .padding(.trailing, 5).help("\(project.name) 폴더 관리").accessibilityLabel("\(project.name) 폴더 관리")
        }.foregroundStyle(SoriTheme.ink)
            .background(selected ? SoriTheme.line.opacity(0.8) : (hoveredProject == project.id ? SoriTheme.line.opacity(0.4) : .clear), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focusedProject == project.id || dropProjectID == project.id ? SoriTheme.accent.opacity(0.55) : .clear).allowsHitTesting(false))
            .onHover { hoveredProject = $0 ? project.id : (hoveredProject == project.id ? nil : hoveredProject) }
    }

    @ViewBuilder private func projectMenu(_ project: Project) -> some View {
        Button("이름 변경", systemImage: "pencil") { folderName = project.name; renaming = project }.disabled(store.busy)
        Divider()
        Button("빈 폴더 삭제", systemImage: "trash", role: .destructive) { store.deleteProject(project) }
            .disabled(store.busy || store.projects.count < 2 || store.recordings.contains { $0.projectID == project.id })
    }
}

private enum LibrarySort: String, CaseIterable {
    case newest = "최근 녹음순", oldest = "오래된 녹음순", title = "제목순", longest = "긴 녹음순"
}

private enum LibraryFilter: String, CaseIterable {
    case all = "전체 상태", saved = "녹음 저장됨", ready = "정리 완료", pending = "진행 · 대기", failed = "확인 필요"
    func includes(_ recording: Recording, queued: Bool) -> Bool {
        switch self {
        case .all: true
        case .saved: recording.status == .saved
        case .ready: recording.status == .ready || recording.status == .noSpeech
        case .pending: recording.status == .recording || queued || recording.status.isProcessing
        case .failed: recording.status == .failed || recording.status == .reviewNeeded
        }
    }
}

struct RecordingRow: View {
    @Bindable var store: AppStore
    let recording: Recording
    let selected: Bool
    let folder: String?
    let query: String
    @State private var hovered = false
    @FocusState private var rowFocused: Bool

    private var preview: String {
        if !query.isEmpty {
            if let match = recording.segments.first(where: { $0.text.localizedCaseInsensitiveContains(query) }) { return snippet(match.text) }
            if recording.notes.localizedCaseInsensitiveContains(query) { return "메모 · " + snippet(recording.notes) }
        }
        if let progress = store.progress(for: recording.id) { return progress.detail }
        if recording.work?.state == .interrupted { return recording.work?.title ?? "이어서 정리할 수 있어요" }
        if let first = recording.segments.first { return first.text }
        if recording.status == .recording { return "음성을 파일로 저장하고 있습니다" }
        if recording.status == .failed { return "녹음을 열어 다시 시도해 주세요" }
        if recording.status == .noSpeech { return "감지된 음성 없음" }
        if recording.status.isProcessing { return "AI가 녹음을 정리하고 있어요" }
        return "음성 파일이 저장되어 있습니다"
    }
    private func snippet(_ text: String) -> String {
        guard let match = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { return text }
        let start = text.index(match.lowerBound, offsetBy: -12, limitedBy: text.startIndex) ?? text.startIndex
        return (start == text.startIndex ? "" : "…") + String(text[start...]).replacingOccurrences(of: "\n", with: " ")
    }
    private var previewText: Text {
        let value = preview
        guard !query.isEmpty, let match = value.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { return Text(value) }
        return Text(String(value[..<match.lowerBound])) + Text(String(value[match])).bold().foregroundColor(SoriTheme.ink) + Text(String(value[match.upperBound...]))
    }
    private var statusTitle: String {
        if let progress = store.progress(for: recording.id) { return progress.stage.step.title + " 중" }
        if recording.work?.state == .interrupted { return recording.id == store.recordingID ? "녹음 일시 정지" : "이어서 정리 가능" }
        return switch recording.status {
        case .recording: "녹음 중"
        case .saved: "녹음 저장됨"
        case .queued: store.queue.contains(recording.id) ? "AI 정리 대기" : "음성 저장됨"
        case .transcribing, .polishing: "AI 정리 중"
        case .ready: "정리 완료"
        case .reviewNeeded: "음성 확인 필요"
        case .noSpeech: "감지된 음성 없음"
        case .failed: "확인 필요"
        }
    }

    var body: some View {
        Button {
            store.select(recording.id)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: recording.status == .recording ? "record.circle" : "waveform")
                    .font(.system(size: 13)).frame(width: 16).padding(.top, 2)
                    .foregroundStyle(recording.status == .recording ? SoriTheme.recording : SoriTheme.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(recording.title).font(.system(size: 14, weight: selected ? .medium : .regular)).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !query.isEmpty { previewText.font(.system(size: 12)).foregroundStyle(SoriTheme.secondary).lineLimit(2) }
                    else if recording.status.isProcessing || recording.status == .failed || recording.work?.state == .interrupted {
                        Text(statusTitle).font(.system(size: 12)).foregroundStyle(SoriTheme.secondary).lineLimit(1)
                    }
                }
            }.padding(.horizontal, 8).padding(.vertical, 9).contentShape(Rectangle())
        }.buttonStyle(.plain).focused($rowFocused).focusEffectDisabled()
            .help("\(recording.title)\n\(folder ?? "") · \(statusTitle) · \(TimeText.clock(recording.duration))")
            .accessibilityLabel("\(recording.title), \(statusTitle), \(TimeText.clock(recording.duration))")
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .background(selected ? SoriTheme.line.opacity(0.65) : (hovered ? SoriTheme.line.opacity(0.3) : .clear), in: RoundedRectangle(cornerRadius: 6))
            .contextMenu { RecordingMenu(store: store, recording: recording) }
            .modifier(RecordingDragModifier(reference: .init(recordingID: recording.id, projectID: recording.projectID), enabled: store.canModify(recording.id)))
            .onHover { hovered = $0 }
    }
}

struct RecordingMenu: View {
    @Bindable var store: AppStore
    let recording: Recording
    private var locked: Bool {
        !store.canModify(recording.id)
    }
    var body: some View {
        Menu("폴더로 이동", systemImage: "folder") {
            ForEach(store.projects) { project in
                Button { store.move(recording, to: project) } label: {
                    if project.id == recording.projectID { Label(project.name, systemImage: "checkmark") }
                    else { Text(project.name) }
                }.disabled(project.id == recording.projectID)
            }
        }.disabled(locked)
        if !recording.segments.isEmpty {
            Button(recording.lectureHighlights == nil ? "핵심 요약 만들기" : "핵심 요약 다시 정리", systemImage: "text.book.closed") {
                store.enqueue(recording.id, lectureOnly: true)
            }.disabled(!store.canOrganizeLecture(recording.id))
            Menu("전사문 내보내기", systemImage: "square.and.arrow.up") {
                Button("텍스트 (.txt)") { store.export(recording, format: "txt") }
                Button("타임코드 자막 (.srt)") { store.export(recording, format: "srt") }
                Button("기록 데이터 (.json)") { store.export(recording, format: "json") }
            }
        } else {
            Button("텍스트로 정리", systemImage: "text.bubble") { store.enqueue(recording.id) }
                .disabled(!store.canTranscribe(recording.id))
        }
        Divider()
        Button("휴지통으로 이동", systemImage: "trash", role: .destructive) { store.trash(recording) }.disabled(locked)
    }
}

struct WelcomeView: View {
    @Bindable var store: AppStore
    private var destination: String {
        store.projects.first { $0.id == store.selectedProjectID }?.name ?? store.projects.first?.name ?? "작업 폴더"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("강의를 기록하세요").font(.system(size: 28, weight: .semibold))
            Text("녹음부터 전사문과 핵심 요약까지 한곳에.")
                .font(.system(size: 15)).foregroundStyle(SoriTheme.secondary)
            HStack(spacing: 12) {
                Button { store.requestRecording() } label: {
                    Label("강의 기록하기", systemImage: "plus")
                }.buttonStyle(.borderedProminent).tint(SoriTheme.ink)
                    .disabled(store.isStartingRecording || store.isFinalizingRecording || store.audio.isRecording || store.repository == nil)
                Button { store.requestRecording(mode: .audioOnly) } label: { Text("녹음하기") }
                    .buttonStyle(.bordered).tint(SoriTheme.ink)
                    .disabled(store.isStartingRecording || store.isFinalizingRecording || store.audio.isRecording || store.repository == nil)
            }.font(.system(size: 14)).controlSize(.large)
            Text("녹음 시작 전 저장할 폴더를 선택합니다.").font(.system(size: 14)).foregroundStyle(SoriTheme.secondary)
            if !store.settings.transcriptionReady {
                Button("음성 인식 설정") { NotificationCenter.default.post(name: Notification.Name("BungBungiShowSettings"), object: nil, userInfo: ["section": "speech"]) }
                    .font(.system(size: 14)).buttonStyle(.plain).foregroundStyle(SoriTheme.ink)
            }
            Button { Task { await store.addDemo() } } label: {
                Label("샘플 녹음 열기", systemImage: "play.circle").font(.system(size: 14))
            }.buttonStyle(.plain).foregroundStyle(SoriTheme.secondary).disabled(store.repository == nil).padding(.top, 10)
        }.frame(maxWidth: 430, alignment: .leading).padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
