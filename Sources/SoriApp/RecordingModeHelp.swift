import SwiftUI

struct RecordingModeHelp: View {
    @State private var presented = false
    @State private var overButton = false
    @State private var overContent = false
    @State private var pinned = false
    @State private var pending: Task<Void, Never>?

    var body: some View {
        Button {
            pending?.cancel()
            if pinned { presented = false; pinned = false }
            else { pinned = true; presented = true }
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(presented ? SoriTheme.ink : SoriTheme.secondary)
                .frame(width: 30, height: 30).contentShape(Rectangle())
        }
        .buttonStyle(.plain).focusEffectDisabled()
        .accessibilityLabel("강의 기록하기와 녹음하기의 차이")
        .accessibilityHint("설명을 열려면 누르세요")
        .onHover { value in overButton = value; updatePresentation() }
        .popover(isPresented: $presented, arrowEdge: .trailing) {
            RecordingModeHelpContent()
                .onHover { value in overContent = value; updatePresentation() }
        }
        .onChange(of: presented) { _, value in
            if !value { pending?.cancel(); pinned = false; overContent = false }
        }
        .onDisappear { pending?.cancel(); presented = false }
    }

    private func updatePresentation() {
        pending?.cancel()
        let hovering = overButton || overContent
        guard !pinned else { return }
        pending = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(hovering ? 180 : 350)) }
            catch { return }
            guard !Task.isCancelled, !pinned else { return }
            presented = overButton || overContent
        }
    }
}

struct RecordingModeHelpContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 21) {
            Text("두 버튼의 차이").font(.system(size: 15, weight: .semibold))
            explanation("강의 기록하기", icon: "text.bubble", text: "녹음과 함께 음성을 처리하고, 마치면 전사문과 핵심 요약까지 정리합니다.")
            explanation("녹음하기", icon: "waveform", text: "음성만 저장합니다. 필요할 때 녹음을 열어 텍스트로 정리할 수 있습니다.")
            Rectangle().fill(SoriTheme.line).frame(height: 1)
            Text("정리가 급하지 않다면 녹음만 해두세요. 음성 인식을 나중으로 미뤄 녹음 중 배터리와 컴퓨터의 부담을 줄일 수 있습니다.")
                .font(.system(size: 12)).foregroundStyle(SoriTheme.secondary)
                .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
        }.padding(23).frame(width: 330, alignment: .leading)
            .background(SoriTheme.paper).foregroundStyle(SoriTheme.ink)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func explanation(_ title: String, icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 16, weight: .regular))
                .foregroundStyle(SoriTheme.secondary).frame(width: 20, height: 21)
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(text).font(.system(size: 13)).foregroundStyle(SoriTheme.secondary)
                    .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
