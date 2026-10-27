import SwiftUI
import DoongdoongCodex

struct AIConnectionSetupView: View {
    @Bindable var store: AppStore
    @State private var copied = false
    @State private var showInstall = false

    var body: some View {
        let settings = store.settings
        let presentation = AIConnectionPresentation(state: settings.connectionState)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let icon = NSImage(contentsOf: AppResources.directory.appendingPathComponent("codex-icon.png")) {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 7)).accessibilityHidden(true)
                }
                Text("AI 연결").font(.system(size: 13, weight: .medium)).foregroundStyle(SoriTheme.secondary)
                Spacer()
                if let issue = settings.connectionIssue {
                    Menu {
                        Button(copied ? "진단 정보 복사됨" : "진단 정보 복사") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("provider=codex\n" + issue.diagnosticSummary, forType: .string)
                            copied = true
                        }
                    } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help("연결 진단 정보").accessibilityLabel("연결 진단 정보")
                }
            }
            Text(presentation.title).font(.system(size: 23, weight: .semibold)).tracking(-0.5)
                .accessibilityAddTraits(.isHeader).padding(.top, 25)
            Text(presentation.message).font(.system(size: 14)).foregroundStyle(SoriTheme.secondary)
                .lineSpacing(5).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            if settings.checkingAI {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(settings.connectionState == .signingIn ? "로그인 완료를 기다리고 있습니다" : "응답 확인 중 · 최대 90초")
                        .font(.system(size: 12)).foregroundStyle(SoriTheme.secondary)
                }.padding(.top, 22)
            }
            if settings.connectionIssue?.kind == .installationRequired {
                DisclosureGroup("설치 방법", isExpanded: $showInstall) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("터미널에서 아래 명령을 실행한 뒤 연결을 다시 확인하세요. Homebrew가 설치되어 있어야 합니다.")
                        HStack {
                            Text(CodexConnection.installationCommand).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            Spacer()
                            Button("복사") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(CodexConnection.installationCommand, forType: .string)
                            }
                        }
                        Button("설치했어요 · 다시 확인") { settings.refreshAIConnection() }
                    }.font(.system(size: 12)).padding(.top, 8)
                }.font(.system(size: 13)).tint(SoriTheme.secondary).padding(.top, 18)
            }
            Rectangle().fill(SoriTheme.line).frame(height: 1).padding(.top, 26).padding(.bottom, 20)
            HStack(spacing: 16) {
                Spacer(minLength: 0)
                Button(presentation.actionTitle) {
                    switch presentation.action {
                    case .retry: settings.refreshAIConnection()
                    case .signIn: settings.signIn { NSWorkspace.shared.open($0) }
                    case .configure: store.openConnectionSettings()
                    case .continueUsing: store.finishConnectionSetup()
                    }
                }.buttonStyle(PrimaryButtonStyle()).disabled(settings.checkingAI).keyboardShortcut(.defaultAction)
            }.font(.system(size: 13))
        }.padding(30).frame(width: 480).background(SoriTheme.paper).foregroundStyle(SoriTheme.ink)
            .focusEffectDisabled().interactiveDismissDisabled()
    }
}
