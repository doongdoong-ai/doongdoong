import SwiftUI
import AVFoundation
import SoriCore
import SoriSpeech
import DoongdoongCodex

struct SettingsView: View {
    @Bindable var store: AppStore
    @State private var tab = 0
    @State private var advanced = false
    @State private var copiedLoginCommand = false
    @State private var providerAdvanced = false
    @State private var codexDraft = ""
    private let viewportHeight: CGFloat
    init(store: AppStore, initialTab: Int = 0, providerDetailsExpanded: Bool = false, viewportHeight: CGFloat = 600) {
        self.store = store; _tab = State(initialValue: initialTab)
        _providerAdvanced = State(initialValue: providerDetailsExpanded)
        _codexDraft = State(initialValue: store.settings.codexPath)
        self.viewportHeight = viewportHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Text("설정").font(.system(size: 20, weight: .semibold))
                Spacer()
                Button("완료") { store.showSettings = false }.keyboardShortcut(.defaultAction)
            }.padding(.bottom, 24)
            Picker("설정 항목", selection: $tab) {
                Text("일반").tag(0); Text("AI 공급자").tag(1); Text("단축키").tag(2)
            }.pickerStyle(.segmented).labelsHidden().padding(.bottom, 24)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if tab == 0 { general }
                    else if tab == 1 { providers }
                    else { shortcuts }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 12)
            }
        }.font(.system(size: 14)).padding(30).frame(width: 600, height: viewportHeight).background(SoriTheme.paper)
            .onChange(of: store.settings.codexPath) { _, _ in copiedLoginCommand = false }
    }

    private var providers: some View {
        @Bindable var settings = store.settings
        return VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                if let icon = NSImage(contentsOf: AppResources.directory.appendingPathComponent("codex-icon.png")) {
                    Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 11)).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Codex").font(.system(size: 18, weight: .semibold)).foregroundStyle(SoriTheme.ink)
                    Text("로그인 · 교정 · 제목 · 핵심 요약").font(.system(size: 13)).foregroundStyle(SoriTheme.secondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    if settings.checkingAI { ProgressView().controlSize(.small) }
                    else { Circle().fill(settings.selectedModel == nil ? SoriTheme.secondary.opacity(0.45) : Color.green).frame(width: 6, height: 6) }
                    Text(settings.checkingAI ? "확인 중" : settings.selectedModel == nil ? "연결 필요" : "연결됨")
                        .font(.system(size: 12)).foregroundStyle(SoriTheme.secondary)
                }
            }.padding(17).background(SoriTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(SoriTheme.ink.opacity(0.08), lineWidth: 1))

            Toggle("녹음 후 AI로 교정·요약", isOn: $settings.analysisEnabled).toggleStyle(.switch).controlSize(.small)
            caption("음성 파일은 ChatGPT에서 전사하고, Mac에서 문장별 재생 위치를 맞춥니다. Codex가 전체 전사문을 교정한 뒤 결과를 보여드립니다.")
            if !settings.analysisEnabled { caption("꺼 두면 음성과 처리 기록을 보관합니다. 전사문을 보려면 AI 교정을 켜고 이어서 정리해 주세요.") }

            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 12) {
                    Button(settings.checkingAI ? "연결 확인 중…" : "연결 다시 확인") { settings.refreshAIConnection() }
                        .disabled(settings.checkingAI || !settings.codexReady)
                    Button(copiedLoginCommand ? "복사됨" : "로그인 명령 복사") { copyLoginCommand() }
                        .disabled(!settings.codexReady)
                }
                caption(settings.codexReady ? settings.aiConnectionMessage : "Codex CLI를 찾지 못했습니다. 아래 실행 경로를 확인해 주세요.")
                if copiedLoginCommand { caption("터미널에 붙여 넣어 로그인한 뒤 연결을 다시 확인하세요.") }
                if let date = settings.lastConnectionCheck {
                    Text("마지막 확인 \(date.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 12)).foregroundStyle(SoriTheme.secondary)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                settingRow("모델") {
                    Picker("모델", selection: $settings.preferredModelID) {
                        Text("자동 · Sol 우선").tag("")
                        ForEach(settings.availableModels) { option in Text(option.displayName).tag(option.id) }
                        if !settings.preferredModelID.isEmpty && !settings.availableModels.contains(where: { $0.id == settings.preferredModelID }) {
                            Text(settings.preferredModelID + " · 확인 필요").tag(settings.preferredModelID)
                        }
                    }.labelsHidden().frame(maxWidth: 270).disabled(settings.checkingAI)
                }
                if settings.preferredModelID.isEmpty {
                    caption("목록에 GPT-6.1 Sol이 있으면 우선 선택하고, 없으면 GPT-6 Luna를 선택합니다. 실행 오류가 나도 모델을 임의로 바꾸지는 않습니다.")
                }
                if let model = settings.selectedModel {
                    Text("적용 모델  \(model.displayName)").font(.system(size: 12)).foregroundStyle(SoriTheme.secondary)
                }
                settingRow("추론 강도") {
                    Picker("추론 강도", selection: $settings.reasoningEffort) {
                        ForEach(settings.availableReasoningEfforts, id: \.self) { Text(effortName($0)).tag($0) }
                        if !settings.availableReasoningEfforts.contains(settings.reasoningEffort) {
                            Text(effortName(settings.reasoningEffort) + " · 확인 필요").tag(settings.reasoningEffort)
                        }
                    }.labelsHidden().frame(maxWidth: 270).disabled(settings.catalog == nil || settings.checkingAI)
                }
                caption("기본값은 Medium입니다. 강도가 높을수록 응답 시간과 사용량이 늘 수 있습니다.")
                settingRow("요청별 응답 제한") {
                    Picker("요청별 응답 제한", selection: $settings.requestTimeout) {
                        ForEach([120.0, 300, 600, 900, 1800], id: \.self) { seconds in Text("\(Int(seconds / 60))분").tag(seconds) }
                        if ![120.0, 300, 600, 900, 1800].contains(settings.requestTimeout) {
                            Text("\(Int(settings.requestTimeout))초").tag(settings.requestTimeout)
                        }
                    }.labelsHidden().frame(maxWidth: 270)
                }
                caption("강의 전체 처리 시간이 아닌, 한 번의 AI 요청에 적용됩니다. 제한을 넘겨도 녹음과 저장된 전사문은 보관합니다.")
            }
            Divider()
            DisclosureGroup("Codex 실행 경로", isExpanded: $providerAdvanced) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Codex CLI 경로", text: $codexDraft).font(.system(size: 12, design: .monospaced))
                        .textFieldStyle(.roundedBorder).onSubmit { applyCodexPath() }
                    HStack {
                        Button("파일 선택…") {
                            let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                            if panel.runModal() == .OK, let url = panel.url { codexDraft = url.path; applyCodexPath() }
                        }
                        Spacer()
                        Button("경로 적용") { applyCodexPath() }.disabled(codexDraft == settings.codexPath || codexDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    caption("Codex CLI의 로그인 정보를 사용합니다. 이 화면에서 API 키를 저장하지 않습니다.")
                }.padding(.top, 12)
            }.onAppear { codexDraft = settings.codexPath }
            caption("변경한 설정은 다음 작업부터 적용됩니다. 모델 목록 확인은 실행 권한이나 남은 사용량 조회가 아닙니다.")
        }
    }
    private func settingRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 20) { Text(title).font(.system(size: 14)); Spacer(minLength: 10); content() }
    }
    private func effortName(_ effort: ReasoningEffort) -> String {
        switch effort {
        case .none: "추론 없음 · None"
        case .minimal: "최소 · Minimal"
        case .low: "빠르게 · Low"
        case .medium: "균형 · Medium"
        case .high: "깊게 · High"
        case .xhigh: "더 깊게 · Extra high"
        case .max: "최대로 · Max"
        case .ultra: "Ultra"
        }
    }
    private func applyCodexPath() {
        store.settings.codexPath = (codexDraft.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        codexDraft = store.settings.codexPath
    }
    private func copyLoginCommand() {
        let executable = "'" + store.settings.codexPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(executable + " login", forType: .string)
        copiedLoginCommand = true
    }

    private var general: some View {
        @Bindable var settings = store.settings
        return VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 12) {
                Text(settings.transcriptionReady ? "AI 정리" : "AI 준비")
                    .font(.system(size: 14, weight: .medium))
                caption("녹음하는 동안 음성을 텍스트로 옮기고, 녹음이 끝나면 전체 내용을 정리합니다.")
                caption("녹음 파일은 ChatGPT 받아쓰기 서버에 전송됩니다. 인터넷 연결과 Codex CLI의 ChatGPT 로그인이 필요합니다.")
                if !settings.transcriptionReady { caption(settings.transcriptionUnavailableReason) }
            }
            HStack {
                Text("녹음 언어").font(.system(size: 14))
                Spacer()
                Menu {
                    ForEach(["ko", "en", "ja", "auto"], id: \.self) { code in
                        Button { settings.language = code } label: {
                            if settings.language == code { Label(languageName(code), systemImage: "checkmark") }
                            else { Text(languageName(code)) }
                        }
                    }
                } label: {
                    Text(languageName(settings.language)).font(.system(size: 14)).foregroundStyle(SoriTheme.ink)
                }.menuStyle(.borderlessButton).fixedSize().tint(SoriTheme.ink)
                    .accessibilityLabel("녹음 언어: \(languageName(settings.language))")
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("AI 공급자").font(.system(size: 14, weight: .medium))
                    caption(settings.analysisEnabled ? "Codex · 교정과 핵심 요약" : "자동 교정·요약 꺼짐")
                }
                Spacer()
                Button("설정하기") { tab = 1 }
            }
            Divider()
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("저장 위치").font(.system(size: 14, weight: .medium))
                    Text(store.root.path).font(.system(size: 13)).foregroundStyle(SoriTheme.secondary)
                        .lineLimit(2).textSelection(.enabled).help(store.root.path)
                }
                Spacer(minLength: 0)
                Button("폴더 열기") { store.reveal() }
            }
            DisclosureGroup("고급 설정", isExpanded: $advanced) {
                VStack(alignment: .leading, spacing: 12) {
                    pathRow("재생 위치 정렬 Python", value: $settings.alignmentPython)
                    pathRow("재생 위치 정렬 모델", value: $settings.alignmentModels, directory: true)
                    pathRow("FFmpeg", value: $settings.ffmpegPath)
                    caption("FFmpeg는 가져온 파일과 전송 파일을 변환합니다. 정렬 모델은 음성과 전사문을 대조해 재생 위치만 찾습니다.")
                    Divider().padding(.vertical, 4)
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("마이크 권한").font(.system(size: 14))
                            caption(microphoneStatus)
                        }
                        Spacer(minLength: 0)
                        Button("권한 설정") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) }
                        }
                    }
                }.padding(.top, 12)
            }.font(.system(size: 14)).foregroundStyle(SoriTheme.secondary)
        }
    }

    private func languageName(_ code: String) -> String {
        ["ko": "한국어", "en": "영어", "ja": "일본어", "auto": "자동 감지"][code] ?? code
    }

    private var microphoneStatus: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "마이크 접근이 허용되어 있습니다."
        case .denied, .restricted: return "녹음하려면 시스템 설정에서 마이크 접근을 허용해 주세요."
        default: return "처음 녹음할 때 마이크 접근 권한을 요청합니다."
        }
    }

    private var shortcuts: some View {
        VStack(spacing: 16) {
            ForEach(Array([
                ("녹음 시작 · 마치기", "⌘R"), ("녹음 일시 정지 · 재개", "⇧⌘R"),
                ("오디오 가져오기", "⌘O"), ("전사문에서 찾기", "⌘F"), ("보관함에서 찾기", "⇧⌘F"),
                ("재생 · 일시 정지", "⇧⌘P"), ("10초 뒤로 · 앞으로", "⌘←  ⌘→"),
                ("북마크 추가", "⌘B"), ("집중 모드", "⇧⌘L")
            ].enumerated()), id: \.offset) { _, entry in
                HStack { Text(entry.0); Spacer(); Text(entry.1).foregroundStyle(SoriTheme.secondary) }.font(.system(size: 14))
            }
            caption("읽기 화면에서는 Space로 재생을 전환할 수 있습니다. 검색이나 메모를 입력할 때는 글자 입력으로 동작합니다.").padding(.top, 10)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(SoriTheme.secondary).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
    }
    private func pathRow(_ title: String, value: Binding<String>, directory: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13))
            HStack {
                TextField(title, text: value).font(.system(size: 13, design: .monospaced)).textFieldStyle(.roundedBorder)
                Button("선택…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = directory; panel.canChooseFiles = !directory; panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url { value.wrappedValue = url.path }
                }
            }
        }
    }
}
