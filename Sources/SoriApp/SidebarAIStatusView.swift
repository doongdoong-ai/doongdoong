import SwiftUI

/// Observes the existing connection check; rendering never starts another request.
struct SidebarAIStatusView: View {
    let settings: AppSettings
    @State private var hovered = false
    private static let providerIcon = NSImage(contentsOf: AppResources.directory.appendingPathComponent("codex-icon.png"))

    private struct Status {
        let label: String
        var color: Color = .white.opacity(0.5)
        var model: String?
        var busy = false
    }

    private var status: Status {
        guard settings.analysisEnabled else { return .init(label: "교정·요약 꺼짐") }
        guard settings.codexReady else { return .init(label: "설치 확인 필요", color: Color(hex: 0xE5BD79)) }
        switch settings.connectionState {
        case .unchecked: return .init(label: "연결 확인 필요")
        case .checking: return .init(label: "연결 확인 중", busy: true)
        case .signingIn: return .init(label: "로그인 대기 중", busy: true)
        case .ready(let model): return .init(label: "연결됨", color: Color(hex: 0x96C5A3), model: model.displayName)
        case .blocked(let issue):
            let label: String
            switch issue.kind {
            case .installationRequired: label = "설치 확인 필요"
            case .loginRequired, .unsupportedAuthentication: label = "로그인 필요"
            case .configuration: label = "설정 확인 필요"
            case .usageLimited: label = "사용 한도 도달"
            case .network, .serviceUnavailable: label = "연결 안 됨"
            case .timedOut, .invalidResponse, .unknown: label = "연결 확인 실패"
            }
            return .init(label: label, color: Color(hex: 0xE5BD79))
        }
    }

    var body: some View {
        let status = self.status
        let lastCheck = settings.lastConnectionCheck.map { "\n마지막 확인 \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
        Button {
            NotificationCenter.default.post(name: Notification.Name("BungBungiShowSettings"), object: nil, userInfo: ["section": "providers"])
        } label: {
            HStack(spacing: 12) {
                if let icon = Self.providerIcon {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 7)).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Codex").font(.system(size: 13, weight: .medium))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(hovered ? 0.8 : 0.4))
                    }
                    HStack(spacing: 6) {
                        if status.busy {
                            ProgressView().controlSize(.mini).frame(width: 7, height: 7).colorScheme(.dark)
                        } else {
                            Circle().fill(status.color).frame(width: 6, height: 6)
                        }
                        Text(status.label).layoutPriority(1)
                        if let model = status.model {
                            Text("· " + model).foregroundStyle(.white.opacity(0.6)).truncationMode(.middle)
                        }
                    }.font(.system(size: 11)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.foregroundStyle(.white).padding(.horizontal, 20).padding(.vertical, 15)
                .frame(maxWidth: .infinity, minHeight: 64)
                .background(Color(hex: hovered ? 0x272826 : 0x191A18))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovered = $0 }
            .help("Codex · \(status.label)\(status.model.map { " · " + $0 } ?? "")\(lastCheck)\nAI 연결 설정 열기")
            .accessibilityLabel("Codex, \(status.label)\(status.model.map { ", " + $0 } ?? "")")
            .accessibilityHint("AI 연결 설정을 엽니다")
    }
}
