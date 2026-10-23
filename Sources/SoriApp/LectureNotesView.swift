import SwiftUI
import SoriCore

struct LectureNotesView: View {
    let recording: Recording
    let isProcessing: Bool
    let canGenerate: Bool
    let canPlay: Bool
    let generate: () -> Void
    let play: (TranscriptSegment) -> Void
    let copied: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let highlights = recording.lectureHighlights {
                    HStack(spacing: 12) {
                        Text("강조한 설명을 모았습니다.")
                            .font(.system(size: 13)).foregroundStyle(SoriTheme.secondary)
                        Spacer(minLength: 4)
                        Button {
                            copyHighlights(([recording.title] + highlights.map(\.copyText)).joined(separator: "\n\n"))
                        } label: { Label("전체 복사", systemImage: "doc.on.doc") }
                            .disabled(highlights.isEmpty).help("핵심 요약 전체 복사").accessibilityLabel("핵심 요약 전체 복사")
                        Menu {
                            Button("핵심 요약 다시 정리", systemImage: "arrow.clockwise") { generate() }.disabled(!canGenerate)
                        } label: { Image(systemName: "ellipsis").frame(width: 24, height: 28) }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            .help("핵심 요약 옵션").accessibilityLabel("핵심 요약 옵션")
                    }.font(.system(size: 12)).buttonStyle(.plain).foregroundStyle(SoriTheme.secondary)
                    if highlights.isEmpty {
                        emptyState(title: "강조한 내용을 찾지 못했습니다.",
                                   detail: "전사문에서 강의 전체를 확인할 수 있습니다.")
                    } else {
                        LazyVStack(spacing: 18) {
                            ForEach(highlights) { card in
                                LectureHighlightCard(card: card, segments: recording.segments, canPlay: canPlay, play: play,
                                                     copy: { copyHighlights(card.copyText) })
                            }
                        }
                    }
                } else {
                    emptyState(title: isProcessing ? "핵심 요약을 정리하고 있습니다." : "중요한 설명을 한곳에.",
                               detail: isProcessing ? "전사문을 읽으며 기다릴 수 있습니다." : "교수님이 강조하거나 반복한 설명을 모으고, 원래 발언과 연결합니다.")
                    if !isProcessing {
                        Button("핵심 요약 만들기", action: generate).buttonStyle(.borderedProminent)
                            .disabled(!canGenerate)
                        if !canGenerate {
                            Text("AI 연결과 진행 중인 작업을 확인해 주세요.")
                                .font(.system(size: 13)).foregroundStyle(SoriTheme.secondary)
                        }
                    }
                }
            }.frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, 38).padding(.top, 22).padding(.bottom, 36)
                .frame(maxWidth: .infinity, alignment: .center)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func emptyState(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 19, weight: .medium))
            Text(detail).font(.system(size: 14)).foregroundStyle(SoriTheme.secondary).lineSpacing(5)
        }.padding(.top, 28).padding(.bottom, 12)
    }
    private func copyHighlights(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied()
    }
}

private struct LectureHighlightCard: View {
    let card: LectureHighlight
    let segments: [TranscriptSegment]
    let canPlay: Bool
    let play: (TranscriptSegment) -> Void
    let copy: () -> Void
    @State private var showEvidence = false

    private var sources: [TranscriptSegment] {
        segments.filter { segment in card.evidence.contains { $0.segmentID == segment.id } }.sorted { $0.start < $1.start }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SelectableCardText(text: card.attributedText)
                .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 20)
            HStack(spacing: 12) {
                if let source = sources.first {
                    Button { play(source) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill").font(.system(size: 9))
                            Text(TimeText.clock(source.start)).monospacedDigit()
                        }.padding(.horizontal, 9).padding(.vertical, 6)
                            .background(SoriTheme.sidebar, in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain).disabled(!canPlay)
                        .help("원래 설명 듣기").accessibilityLabel("\(card.heading), \(TimeText.clock(source.start))에서 재생")
                }
                Text(card.signal == .explicit ? "직접 강조" : "반복 설명")
                    .foregroundStyle(SoriTheme.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Button { showEvidence.toggle() } label: {
                    HStack(spacing: 5) {
                        Text(showEvidence ? "근거 접기" : "근거 보기")
                        Image(systemName: showEvidence ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .medium))
                    }.padding(.vertical, 6)
                }.buttonStyle(.plain).foregroundStyle(SoriTheme.secondary)
                    .accessibilityValue(showEvidence ? "펼쳐짐" : "접힘")
                Button(action: copy) { Image(systemName: "doc.on.doc").frame(width: 28, height: 28) }
                    .buttonStyle(QuietButtonStyle()).foregroundStyle(SoriTheme.secondary)
                    .help("요약 복사").accessibilityLabel("\(card.heading) 요약 복사")
            }.font(.system(size: 12)).padding(.leading, 24).padding(.trailing, 16).padding(.bottom, 12)
            if showEvidence {
                Rectangle().fill(SoriTheme.line).frame(height: 1).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(card.evidence.sorted { $0.segmentID < $1.segmentID }) { evidence in
                        VStack(alignment: .leading, spacing: 10) {
                            SelectableCardText(text: LectureHighlight.quoteText(evidence.quote))
                                .padding(.leading, 14)
                                .overlay(alignment: .leading) { Rectangle().fill(SoriTheme.line).frame(width: 2) }
                            if let source = sources.first(where: { $0.id == evidence.segmentID }) {
                                Button { play(source) } label: {
                                    Label("\(TimeText.clock(source.start)) · 원래 설명 듣기", systemImage: "play.fill")
                                }.font(.system(size: 12)).buttonStyle(.plain).disabled(!canPlay)
                                    .padding(.leading, 14)
                            }
                        }
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading).background(SoriTheme.sidebar.opacity(0.45))
            }
        }.foregroundStyle(SoriTheme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(SoriTheme.line.opacity(0.75)).allowsHitTesting(false))
            .onAppear { if BungBungiApp.runsWithoutUI && ProcessInfo.processInfo.arguments.contains("--evidence-preview") { showEvidence = true } }
    }
}

extension LectureHighlight {
    var copyText: String { heading + "\n" + summary }

    var attributedText: NSAttributedString {
        let result = NSMutableAttributedString()
        let headingStyle = NSMutableParagraphStyle(); headingStyle.paragraphSpacing = 11; headingStyle.lineBreakStrategy = .hangulWordPriority
        result.append(NSAttributedString(string: heading + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 18, weight: .semibold),
            .foregroundColor: NSColor(SoriTheme.ink), .paragraphStyle: headingStyle
        ]))
        let bodyStyle = NSMutableParagraphStyle(); bodyStyle.lineSpacing = 7; bodyStyle.lineBreakStrategy = .hangulWordPriority
        result.append(NSAttributedString(string: summary, attributes: [
            .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor(SoriTheme.ink), .paragraphStyle: bodyStyle
        ]))
        return result
    }

    static func quoteText(_ quote: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle(); style.lineSpacing = 6; style.lineBreakStrategy = .hangulWordPriority
        return NSAttributedString(string: quote, attributes: [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor(SoriTheme.secondary), .paragraphStyle: style
        ])
    }
}
