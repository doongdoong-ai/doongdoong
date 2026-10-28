import SwiftUI

/// Observes the existing connection check; rendering never starts another request.
struct SidebarAIStatusView: View {
    let settings: AppSettings
    @State private var hovered = false
    private static let icons = Dictionary(uniqueKeysWithValues: AIVendor.allCases.map {
        ($0, NSImage(contentsOf: AppResources.directory.appendingPathComponent($0.iconResource)))
    })

    private struct Status {
        let label: String
        var color: Color = .white.opacity(0.5)
        var model: String?
        var busy = false
    }

    private var status: Status {
        guard settings.analysisEnabled else { return .init(label: "교정·요약 꺼짐") }
        let status = AIVendorStatus(settings: settings, vendor: settings.vendor)
        let color: Color = switch status.tone {
        case .neutral: .white.opacity(0.5)
        case .ready: Color(hex: 0x96C5A3)
        case .attention: Color(hex: 0xE5BD79)
        }
        return .init(label: status.label, color: color, model: status.model, busy: status.busy)
    }

    var body: some View {
        let status = self.status
        let lastCheck = settings.lastConnectionCheck.map { "\n마지막 확인 \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
        Button {
            NotificationCenter.default.post(name: Notification.Name("BungBungiShowSettings"), object: nil, userInfo: ["section": "providers"])
        } label: {
            HStack(spacing: 12) {
                if let icon = Self.icons[settings.vendor] ?? nil {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 7)).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(settings.vendor.name).font(.system(size: 13, weight: .medium))
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
            .help("\(settings.vendor.name) · \(status.label)\(status.model.map { " · " + $0 } ?? "")\(lastCheck)\nAI 연결 설정 열기")
            .accessibilityLabel("\(settings.vendor.name), \(status.label)\(status.model.map { ", " + $0 } ?? "")")
            .accessibilityHint("AI 연결 설정을 엽니다")
    }
}
