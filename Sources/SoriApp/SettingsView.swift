import SwiftUI
import AVFoundation
import SoriCore
import SoriSpeech

struct SettingsView: View {
    @Bindable var store: AppStore
    @State private var tab = 0
    @State private var advanced = false
    @State private var copiedLoginCommand = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Text("설정").font(.system(size: 20, weight: .semibold))
                Spacer()
                Button("완료") { store.showSettings = false }.keyboardShortcut(.defaultAction)
            }.padding(.bottom, 24)
            Picker("설정 항목", selection: $tab) {
                Text("일반").tag(0); Text("단축키").tag(1)
            }.pickerStyle(.segmented).labelsHidden().padding(.bottom, 24)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if tab == 0 { general }
                    else { shortcuts }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 12)
            }
        }.font(.system(size: 14)).padding(30).frame(width: 600, height: 600).background(SoriTheme.paper)
            .onChange(of: store.settings.codexPath) { _, _ in copiedLoginCommand = false }
    }

    private var general: some View {
        @Bindable var settings = store.settings
        return VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 12) {
                Text(settings.transcriptionReady ? "AI 정리" : "AI 준비")
                    .font(.system(size: 14, weight: .medium))
                caption("녹음하는 동안 음성을 텍스트로 옮기고, 녹음이 끝나면 전체 내용을 정리합니다.")
                caption("음성 인식은 Mac에서 처리합니다. 교정과 핵심 요약에는 전사된 텍스트만 AI로 전달합니다.")
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
            VStack(alignment: .leading, spacing: 12) {
                Text("AI 연결").font(.system(size: 14, weight: .medium))
                caption("교정·제목·핵심 요약에 연결된 ChatGPT 계정을 사용합니다. 연결하지 않아도 녹음과 전사는 가능합니다.")
                HStack(spacing: 12) {
                    Button(settings.checkingAI ? "확인 중…" : "AI 연결 확인") {
                        copiedLoginCommand = false
                        settings.refreshAIConnection()
                    }.disabled(settings.checkingAI || !settings.codexReady)
                    if settings.checkingAI { ProgressView().controlSize(.small) }
                    if settings.codexReady && settings.connectionState == .loginRequired {
                        Button("로그인 명령 복사") {
                            let executable = "'" + settings.codexPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(executable + " login", forType: .string)
                            copiedLoginCommand = true
                        }
                    }
                }
                if !settings.codexReady { caption("AI 연결 프로그램을 찾을 수 없습니다. 고급 설정에서 경로를 확인하세요.") }
                else { caption(settings.aiConnectionMessage) }
                if copiedLoginCommand { caption("로그인 명령을 복사했습니다. 터미널에 붙여 넣어 실행하세요.") }
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
                    pathRow("Whisper 실행 파일", value: $settings.whisperPath)
                    pathRow("음성 인식 모델", value: $settings.whisperModel)
                    pathRow("음성 감지 모델", value: $settings.vadModel)
                    pathRow("Codex CLI", value: $settings.codexPath)
                    pathRow("FFmpeg", value: $settings.ffmpegPath)
                    if let model = settings.selectedModel {
                        caption("사용 모델: \(model.displayName) · \(CodexModel.reasoningEffort)")
                    }
                    caption("앱을 열 때 사용할 수 있는 모델을 확인합니다. Sol을 우선 사용하며, 목록에 없으면 Luna를 선택합니다.")
                    caption("FFmpeg는 가져온 파일을 녹음 형식으로 변환하는 데에 사용합니다.")
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
