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
            VStack(alignment: .leading, spacing: 0) {
                if let highlights = recording.lectureHighlights {
                    HStack(spacing: 12) {
                        Text("교수님이 강조한 내용")
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
                    }.font(.system(size: 13)).buttonStyle(.plain).foregroundStyle(SoriTheme.secondary)
                        .padding(.bottom, 6)
                    if highlights.isEmpty {
                        emptyState(title: "강조한 내용을 찾지 못했습니다.",
                                   detail: "전사문에서 강의 전체를 확인할 수 있습니다.")
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(highlights) { highlight in
                                LectureSummarySection(highlight: highlight, segments: recording.segments, canPlay: canPlay, play: play,
                                                      copy: { copyHighlights(highlight.copyText) })
                                if highlight.id != highlights.last?.id {
                                    Rectangle().fill(SoriTheme.line).frame(height: 1).accessibilityHidden(true)
                                }
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
            }.frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 44).padding(.top, 24).padding(.bottom, 42)
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

private struct LectureSummarySection: View {
    let highlight: LectureHighlight
    let segments: [TranscriptSegment]
    let canPlay: Bool
    let play: (TranscriptSegment) -> Void
    let copy: () -> Void
    @State private var showEvidence = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var sources: [TranscriptSegment] {
        segments.filter { segment in highlight.evidence.contains { $0.segmentID == segment.id } }.sorted { $0.start < $1.start }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Text(highlight.signal == .explicit ? "강조한 개념" : "반복해서 설명한 내용")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(SoriTheme.secondary)
                Spacer()
                Button(action: copy) { Image(systemName: "doc.on.doc").font(.system(size: 14)).frame(width: 28, height: 28) }
                    .buttonStyle(SummaryActionStyle()).help("이 내용 복사").accessibilityLabel("\(highlight.heading) 요약 복사")
            }.padding(.bottom, 8)

            SelectableCardText(text: highlight.attributedText)

            HStack(spacing: 20) {
                if let source = sources.first {
                    Button { play(source) } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "play.circle.fill").font(.system(size: 19, weight: .regular))
                            Text(TimeText.clock(source.start)).monospacedDigit()
                            Text("설명 듣기")
                        }.padding(.vertical, 8)
                    }.buttonStyle(SummaryActionStyle()).disabled(!canPlay)
                        .help("전사문의 해당 위치에서 재생").accessibilityLabel("\(highlight.heading), \(TimeText.clock(source.start))에서 재생")
                }
                if !highlight.evidence.isEmpty {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { showEvidence.toggle() }
                    } label: {
                        HStack(spacing: 7) {
                            Text(showEvidence ? "발언 접기" : "관련 발언")
                            Image(systemName: "chevron.down").font(.system(size: 11, weight: .medium))
                                .rotationEffect(.degrees(showEvidence ? 180 : 0))
                        }.padding(.vertical, 8)
                    }.buttonStyle(SummaryActionStyle())
                        .accessibilityLabel("\(highlight.heading) 관련 발언")
                        .accessibilityValue(showEvidence ? "펼쳐짐" : "접힘")
                }
                Spacer(minLength: 0)
            }.font(.system(size: 13)).padding(.top, 14)

            if showEvidence {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(highlight.evidence.sorted { $0.segmentID < $1.segmentID }) { evidence in
                        HStack(alignment: .top, spacing: 16) {
                            Image(systemName: "quote.opening").font(.system(size: 18, weight: .medium))
                                .foregroundStyle(SoriTheme.faint).frame(width: 18).padding(.top, 3).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 10) {
                                SelectableCardText(text: LectureHighlight.quoteText(evidence.quote))
                                if let source = sources.first(where: { $0.id == evidence.segmentID }) {
                                    Button { play(source) } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "play.fill").font(.system(size: 10))
                                            Text("\(TimeText.clock(source.start))에서 듣기").monospacedDigit()
                                        }
                                    }.font(.system(size: 13)).buttonStyle(SummaryActionStyle()).disabled(!canPlay)
                                }
                            }
                        }
                    }
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                    .background(SoriTheme.sidebar, in: RoundedRectangle(cornerRadius: 10))
                    .padding(.top, 12).transition(.opacity)
            }
        }.foregroundStyle(SoriTheme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 26)
            .onAppear { if BungBungiApp.runsWithoutUI && ProcessInfo.processInfo.arguments.contains("--evidence-preview") { showEvidence = true } }
    }
}

private struct SummaryActionStyle: ButtonStyle {
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(hovered ? SoriTheme.ink : SoriTheme.secondary)
            .opacity(enabled ? (configuration.isPressed ? 0.55 : 1) : 0.4)
            .contentShape(Rectangle()).onHover { hovered = $0 }
    }
}

extension LectureHighlight {
    var copyText: String { heading + "\n" + summary }

    var attributedText: NSAttributedString {
        let result = NSMutableAttributedString()
        let headingStyle = NSMutableParagraphStyle(); headingStyle.paragraphSpacing = 13; headingStyle.lineSpacing = 3; headingStyle.lineBreakStrategy = .hangulWordPriority
        result.append(NSAttributedString(string: heading + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
            .foregroundColor: NSColor(SoriTheme.ink), .paragraphStyle: headingStyle
        ]))
        let bodyStyle = NSMutableParagraphStyle(); bodyStyle.lineSpacing = 8; bodyStyle.lineBreakStrategy = .hangulWordPriority
        result.append(NSAttributedString(string: summary, attributes: [
            .font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor(SoriTheme.ink), .paragraphStyle: bodyStyle
        ]))
        return result
    }

    static func quoteText(_ quote: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle(); style.lineSpacing = 6; style.lineBreakStrategy = .hangulWordPriority
        return NSAttributedString(string: quote, attributes: [
            .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor(SoriTheme.secondary), .paragraphStyle: style
        ])
    }
}
