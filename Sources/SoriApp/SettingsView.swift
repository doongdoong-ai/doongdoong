import SwiftUI
import AVFoundation
import SoriCore
import SoriSpeech
import DoongdoongCodex

enum SettingsSection: String, CaseIterable {
    case speech, providers, shortcuts
    var title: String {
        switch self { case .speech: "음성 인식"; case .providers: "AI 연결"; case .shortcuts: "단축키" }
    }
    var symbol: String {
        switch self { case .speech: "waveform"; case .providers: "slider.horizontal.3"; case .shortcuts: "keyboard" }
    }
    var subtitle: String {
        switch self {
        case .speech: "강의의 음성을 이 Mac에서 텍스트로 옮깁니다."
        case .providers: "전사문을 다듬고, 강의의 핵심을 정리합니다."
        case .shortcuts: "녹음과 복습을 키보드로 더 빠르게."
        }
    }
}

struct SettingsView: View {
    static let defaultSize = NSSize(width: 820, height: 700)
    static let minimumSize = NSSize(width: 760, height: 600)
    @Bindable var store: AppStore
    @State private var advanced = false
    @State private var copiedLoginCommand = false
    @State private var providerAdvanced = false
    @State private var codexDraft: String
    @State private var ffmpegDraft: String
    @State private var codexPathError: String?
    @State private var ffmpegPathError: String?

    init(store: AppStore, providerDetailsExpanded: Bool = false) {
        self.store = store
        _providerAdvanced = State(initialValue: providerDetailsExpanded)
        _codexDraft = State(initialValue: store.settings.codexPath)
        _ffmpegDraft = State(initialValue: store.settings.ffmpegPath)
    }

    var body: some View {
        HStack(spacing: 0) {
            navigation
            Rectangle().fill(SoriTheme.line).frame(width: 1)
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 26) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(store.settingsSection.title).font(.system(size: 24, weight: .semibold))
                                    .accessibilityAddTraits(.isHeader)
                                note(store.settingsSection.subtitle)
                            }
                            switch store.settingsSection {
                            case .speech: general
                            case .providers: providers
                            case .shortcuts: shortcuts
                            }
                        }.frame(maxWidth: 640, alignment: .leading).padding(32)
                            .frame(maxWidth: .infinity, alignment: .topLeading).id("top")
                    }
                    .onChange(of: store.settingsSection) { _, _ in proxy.scrollTo("top", anchor: .top) }
                    .task(id: providerAdvanced) {
                        guard providerAdvanced else { return }
                        // Let the expanded content participate in layout before revealing its controls.
                        try? await Task.sleep(for: .milliseconds(100))
                        guard !Task.isCancelled, store.settingsSection == .providers else { return }
                        proxy.scrollTo("provider-advanced-end", anchor: .bottom)
                    }
                }
                HStack {
                    Text("설정은 다음 작업부터 적용됩니다.")
                        .font(.system(size: 12)).foregroundStyle(SoriTheme.secondary)
                    Spacer()
                    Button("닫기") { store.showSettings = false }
                        .keyboardShortcut(.cancelAction).disabled(store.isInstalling)
                }.padding(.horizontal, 32).padding(.vertical, 16)
                    .overlay(alignment: .top) { Rectangle().fill(SoriTheme.line).frame(height: 1) }
            }.background(SoriTheme.paper)
        }.font(.system(size: 14)).foregroundStyle(SoriTheme.ink)
            .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
            .onAppear {
                if !store.settings.preparingSpeech { store.settings.refreshSpeechAvailability() }
            }
            .onChange(of: codexDraft) { _, _ in codexPathError = nil }
            .onChange(of: ffmpegDraft) { _, _ in ffmpegPathError = nil }
            .onChange(of: store.settings.codexPath) { _, value in codexDraft = value; copiedLoginCommand = false }
            .onChange(of: store.settings.ffmpegPath) { _, value in ffmpegDraft = value }
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("설정").font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 14).padding(.top, 32).padding(.bottom, 25)
            ForEach(SettingsSection.allCases, id: \.self) { section in
                Button { store.settingsSection = section } label: {
                    Label(section.title, systemImage: section.symbol)
                        .font(.system(size: 13, weight: store.settingsSection == section ? .medium : .regular))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .contentShape(Rectangle())
                }.buttonStyle(SettingsNavigationStyle(selected: store.settingsSection == section))
                    .accessibilityAddTraits(store.settingsSection == section ? [.isSelected] : [])
                    .padding(.bottom, 4)
            }
            Spacer()
            Text("둥둥이").font(.system(size: 12, weight: .medium)).foregroundStyle(SoriTheme.secondary)
                .padding(.horizontal, 14).padding(.bottom, 23)
        }.padding(.horizontal, 12).frame(width: 184).background(SoriTheme.sidebar)
    }

    private var general: some View {
        @Bindable var settings = store.settings
        return VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 13) {
                Image(systemName: "apple.logo").font(.system(size: 25))
                    .frame(width: 44, height: 44).background(SoriTheme.sidebar, in: RoundedRectangle(cornerRadius: 11))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Apple Speech").font(.system(size: 16, weight: .semibold))
                    note("음성은 Mac 안에서 처리됩니다.")
                }
                Spacer(minLength: 12)
                status(speechBadge, ready: settings.speechAvailability == .ready && settings.speechPreparationError == nil,
                       busy: settings.preparingSpeech || settings.speechAvailability == nil || settings.speechAvailability == .downloading)
            }
            group("언어") {
                row("녹음 언어", detail: "강의에서 주로 사용하는 언어") {
                    Picker("녹음 언어", selection: $settings.language) {
                        Text("한국어").tag("ko"); Text("영어").tag("en"); Text("일본어").tag("ja")
                    }.labelsHidden().frame(width: 156, alignment: .trailing).disabled(settings.preparingSpeech)
                }
                rule
                VStack(alignment: .leading, spacing: 12) {
                    row("언어 모델", detail: speechDetail) {
                        if settings.preparingSpeech {
                            Button("취소") { settings.cancelSpeechPreparation() }
                        } else if settings.transcriptionReady && settings.speechAvailability != nil && settings.speechAvailability != .ready && settings.speechAvailability != .downloading {
                            Button("다운로드") { settings.prepareSpeech() }.buttonStyle(.borderedProminent)
                        } else {
                            Button { settings.refreshSpeechAvailability() } label: { Image(systemName: "arrow.clockwise") }
                                .help("언어 모델 상태 다시 확인").accessibilityLabel("언어 모델 상태 다시 확인")
                                .disabled(settings.speechAvailability == nil)
                        }
                    }
                    if case .downloading(let fraction) = settings.speechPreparation {
                        ProgressView(value: fraction).accessibilityLabel("언어 모델 다운로드")
                    } else if settings.preparingSpeech || settings.speechAvailability == .downloading {
                        ProgressView().controlSize(.small).accessibilityLabel("언어 모델 준비 중")
                    }
                }
            }
            group("녹음") {
                row("마이크 접근", detail: microphoneStatus) {
                    Button("시스템 설정…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) }
                    }
                }
            }
            DisclosureGroup("파일 가져오기", isExpanded: $advanced) {
                VStack(alignment: .leading, spacing: 12) {
                    note("오디오·동영상 파일을 변환하는 FFmpeg의 위치입니다.")
                    executableField("FFmpeg", draft: $ffmpegDraft, error: ffmpegPathError,
                                    saved: settings.ffmpegPath) { applyPath(isCodex: false) }
                }.padding(.top, 16)
            }.font(.system(size: 13)).tint(SoriTheme.secondary)
        }
    }

    private var speechBadge: String {
        let settings = store.settings
        if settings.speechPreparationError != nil { return "확인 필요" }
        if settings.preparingSpeech { return "준비 중" }
        switch settings.speechAvailability {
        case .ready: return "준비됨"
        case .downloadRequired: return "모델 필요"
        case .downloading: return "다운로드 중"
        case .unavailable, .unsupportedLanguage: return "지원 안 됨"
        case nil: return "확인 중"
        }
    }
    private var speechDetail: String {
        let settings = store.settings
        if let error = settings.speechPreparationError { return error }
        if settings.preparingSpeech { return "macOS에서 언어 모델을 준비하고 있습니다." }
        switch settings.speechAvailability {
        case .ready: return "준비 완료 · 인터넷 없이 인식합니다."
        case .downloadRequired: return "처음 한 번 다운로드가 필요합니다."
        case .downloading: return "macOS에서 다운로드하고 있습니다."
        case .unsupportedLanguage: return "이 Mac에서 지원하는 다른 언어를 선택해 주세요."
        case .unavailable: return "이 Mac에서는 음성 인식을 사용할 수 없습니다."
        case nil: return "지원 여부를 확인하고 있습니다."
        }
    }

    private var providers: some View {
        @Bindable var settings = store.settings
        return VStack(alignment: .leading, spacing: 24) {
            connection
            VStack(alignment: .leading, spacing: 12) {
                row("녹음 후 교정·요약", detail: "녹음이 끝나면 전체 내용을 정리합니다.") {
                    Toggle("녹음 후 교정·요약", isOn: $settings.analysisEnabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                if !settings.analysisEnabled {
                    note("음성과 처리 기록은 보관됩니다. 전사문을 보려면 교정을 켜고 이어서 정리해 주세요.")
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(SoriTheme.sidebar, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            group("모델") {
                row("사용할 모델", detail: modelDetail) {
                    Picker("사용할 모델", selection: $settings.preferredModelID) {
                        Text("자동 선택").tag("")
                        ForEach(settings.availableModels) { Text($0.displayName).tag($0.id) }
                        if !settings.preferredModelID.isEmpty && !settings.availableModels.contains(where: { $0.id == settings.preferredModelID }) {
                            Text(settings.preferredModelID + " · 확인 필요").tag(settings.preferredModelID)
                        }
                    }.labelsHidden().frame(width: 190, alignment: .trailing).disabled(settings.checkingAI)
                }
                rule
                row("추론 강도", detail: "높을수록 시간과 사용량이 늘 수 있습니다.") {
                    Picker("추론 강도", selection: $settings.reasoningEffort) {
                        ForEach(settings.availableReasoningEfforts, id: \.self) { Text(effortName($0)).tag($0) }
                        if !settings.availableReasoningEfforts.contains(settings.reasoningEffort) {
                            Text(effortName(settings.reasoningEffort) + " · 확인 필요").tag(settings.reasoningEffort)
                        }
                    }.labelsHidden().frame(width: 190, alignment: .trailing).disabled(settings.catalog == nil || settings.checkingAI)
                }
            }
            DisclosureGroup("고급 설정", isExpanded: $providerAdvanced) {
                VStack(alignment: .leading, spacing: 20) {
                    row("요청 제한 시간", detail: "한 번의 AI 요청을 기다리는 최대 시간") {
                        Picker("요청 제한 시간", selection: $settings.requestTimeout) {
                            ForEach([120.0, 300, 600, 900, 1800], id: \.self) { seconds in Text("\(Int(seconds / 60))분").tag(seconds) }
                            if ![120.0, 300, 600, 900, 1800].contains(settings.requestTimeout) {
                                Text("\(Int(settings.requestTimeout))초").tag(settings.requestTimeout)
                            }
                        }.labelsHidden().frame(width: 156, alignment: .trailing)
                    }
                    rule
                    executableField("Codex 실행 파일", draft: $codexDraft, error: codexPathError,
                                    saved: settings.codexPath) { applyPath(isCodex: true) }
                    HStack {
                        Button(copiedLoginCommand ? "로그인 명령 복사됨" : "로그인 명령 복사") { copyLoginCommand() }.disabled(!settings.codexReady)
                        Spacer()
                    }
                    note("자동 선택은 Sol을 우선하고, 없으면 Luna를 사용합니다. 모델 목록 확인은 잔여 사용량 확인이 아닙니다.").id("provider-advanced-end")
                }.padding(.top, 18)
            }.font(.system(size: 13)).tint(SoriTheme.secondary).id("provider-advanced")
            note("교정·요약에는 텍스트만 전달되며, ChatGPT 계정의 이용 한도가 적용됩니다.")
        }
    }

    private var connection: some View {
        let settings = store.settings
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                if let icon = NSImage(contentsOf: AppResources.directory.appendingPathComponent("codex-icon.png")) {
                    Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).frame(width: 42, height: 42)
                        .clipShape(RoundedRectangle(cornerRadius: 10)).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Codex").font(.system(size: 16, weight: .semibold))
                    note("ChatGPT 계정으로 연결")
                }
                Spacer()
                status(connectionBadge, ready: settings.selectedModel != nil, busy: settings.checkingAI)
            }
            if settings.selectedModel == nil && !settings.checkingAI {
                note(settings.codexReady ? settings.aiConnectionMessage : "Codex 실행 파일을 찾지 못했습니다. 실행 경로를 확인해 주세요.")
            }
            rule
            HStack(spacing: 12) {
                if !settings.codexReady {
                    Button("실행 경로 설정") { providerAdvanced = true }
                } else if settings.connectionState == .loginRequired {
                    Button(copiedLoginCommand ? "복사됨" : "로그인 명령 복사") { copyLoginCommand() }
                        .buttonStyle(.borderedProminent)
                } else if let date = settings.lastConnectionCheck {
                    Text("마지막 확인 \(date.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 12)).foregroundStyle(SoriTheme.secondary)
                }
                Spacer(minLength: 0)
                Button(settings.checkingAI ? "확인 중…" : "연결 확인") { settings.refreshAIConnection() }
                    .disabled(settings.checkingAI || !settings.codexReady)
            }
            if copiedLoginCommand { note("터미널에 붙여 넣어 로그인한 뒤 연결을 확인하세요.") }
        }.padding(18).background(.white, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(SoriTheme.line))
    }
    private var connectionBadge: String {
        if !store.settings.codexReady { return "설정 필요" }
        switch store.settings.connectionState {
        case .ready: return "연결됨"
        case .checking: return "확인 중"
        case .loginRequired: return "로그인 필요"
        case .unavailable, .failed: return "확인 필요"
        case .unchecked: return "연결 전"
        }
    }
    private var modelDetail: String {
        if let model = store.settings.selectedModel { return "현재 \(model.displayName)" }
        return store.settings.preferredModelID.isEmpty ? "연결된 계정에서 자동으로 선택합니다." : "연결 확인 후 사용할 수 있습니다."
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 24) {
            shortcutGroup("녹음", entries: [("녹음 시작 · 마치기", ["⌘", "R"]), ("일시 정지 · 재개", ["⇧", "⌘", "R"]), ("파일 가져오기", ["⌘", "O"])])
            shortcutGroup("복습", entries: [("재생 · 일시 정지", ["⇧", "⌘", "P"]), ("10초 뒤로", ["⌘", "←"]), ("10초 앞으로", ["⌘", "→"]), ("북마크 추가", ["⌘", "B"]), ("집중 모드", ["⇧", "⌘", "L"])])
            shortcutGroup("검색", entries: [("전사문에서 찾기", ["⌘", "F"]), ("보관함에서 찾기", ["⇧", "⌘", "F"])])
            note("읽기 화면에서는 Space로도 재생할 수 있습니다. 검색·메모 입력 중에는 글자 입력으로 동작합니다.")
        }
    }
    private func shortcutGroup(_ title: String, entries: [(String, [String])]) -> some View {
        group(title) {
            ForEach(entries.indices, id: \.self) { index in
                HStack {
                    Text(entries[index].0)
                    Spacer()
                    HStack(spacing: 4) {
                        ForEach(Array(entries[index].1.enumerated()), id: \.offset) { _, key in
                            Text(key).font(.system(size: 12, weight: .medium, design: .monospaced))
                                .frame(minWidth: 24, minHeight: 24)
                                .background(.white, in: RoundedRectangle(cornerRadius: 5))
                                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(SoriTheme.line))
                        }
                    }.accessibilityElement(children: .ignore).accessibilityLabel(entries[index].1.joined(separator: " "))
                }.padding(.vertical, 3)
            }
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(SoriTheme.secondary).accessibilityAddTraits(.isHeader)
            content()
        }
    }
    private func row<Content: View>(_ title: String, detail: String, @ViewBuilder control: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 14, weight: .medium))
                note(detail)
            }.frame(maxWidth: .infinity, alignment: .leading)
            control().controlSize(.regular).fixedSize(horizontal: true, vertical: false)
        }.padding(.vertical, 2)
    }
    private var rule: some View { Rectangle().fill(SoriTheme.line).frame(height: 1) }
    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(SoriTheme.secondary)
            .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
    }
    private func status(_ text: String, ready: Bool, busy: Bool) -> some View {
        HStack(spacing: 6) {
            if busy { ProgressView().controlSize(.mini) }
            else { Circle().fill(ready ? SoriTheme.green : SoriTheme.faint).frame(width: 5, height: 5) }
            Text(text).font(.system(size: 12)).foregroundStyle(ready ? SoriTheme.green : SoriTheme.secondary)
        }.fixedSize().accessibilityElement(children: .ignore).accessibilityLabel(text)
    }
    private func executableField(_ title: String, draft: Binding<String>, error: String?, saved: String, apply: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .medium))
            TextField(title, text: draft).font(.system(size: 12, design: .monospaced))
                .textFieldStyle(.roundedBorder).onSubmit(apply)
            HStack {
                Button("파일 선택…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url { draft.wrappedValue = url.path; apply() }
                }
                Spacer()
                Button("적용", action: apply).disabled(draft.wrappedValue == saved || draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(SoriTheme.recording).fixedSize(horizontal: false, vertical: true) }
        }
    }
    private func applyPath(isCodex: Bool) {
        let value = ((isCodex ? codexDraft : ffmpegDraft).trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: value, isDirectory: &isDirectory), !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: value) else {
            if isCodex { codexPathError = "실행할 수 있는 Codex 파일을 선택해 주세요." }
            else { ffmpegPathError = "실행할 수 있는 FFmpeg 파일을 선택해 주세요." }
            return
        }
        if isCodex { codexPathError = nil; store.settings.codexPath = value; codexDraft = value }
        else { ffmpegPathError = nil; store.settings.ffmpegPath = value; ffmpegDraft = value }
    }
    private func copyLoginCommand() {
        let executable = "'" + store.settings.codexPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(executable + " login", forType: .string)
        copiedLoginCommand = true
    }
    private func effortName(_ effort: ReasoningEffort) -> String {
        switch effort {
        case .none: "None"
        case .minimal: "Minimal"
        case .low: "Low · 빠르게"
        case .medium: "Medium · 균형"
        case .high: "High · 깊게"
        case .xhigh: "Extra high"
        case .max: "Max"
        case .ultra: "Ultra"
        }
    }
    private var microphoneStatus: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: "허용됨 · 새 녹음을 시작할 수 있습니다."
        case .denied, .restricted: "시스템 설정에서 마이크 접근을 허용해 주세요."
        default: "처음 녹음할 때 접근 권한을 요청합니다."
        }
    }
}

private struct SettingsNavigationStyle: ButtonStyle {
    var selected: Bool
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(selected ? SoriTheme.ink : SoriTheme.secondary)
            .background(selected ? SoriTheme.line : (configuration.isPressed || hovered ? SoriTheme.line.opacity(0.6) : .clear), in: RoundedRectangle(cornerRadius: 7))
            .onHover { hovered = $0 }
    }
}
