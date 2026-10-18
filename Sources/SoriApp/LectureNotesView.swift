import SwiftUI
import SoriCore

struct LectureNotesView: View {
    let recording: Recording
    let isProcessing: Bool
    let canGenerate: Bool
    let canPlay: Bool
    let generate: () -> Void
    let play: (TranscriptSegment) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if let highlights = recording.lectureHighlights {
                    HStack(alignment: .top, spacing: 20) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("강조한 내용").font(.system(size: 21, weight: .semibold)).tracking(-0.3)
                            Text("전사문의 강조 표현과 반복 설명을 바탕으로 AI가 정리했어요.")
                                .font(.system(size: 14)).foregroundStyle(SoriTheme.secondary).lineSpacing(4)
                        }
                        Spacer(minLength: 0)
                        Button("다시 정리") { generate() }
                            .font(.system(size: 13)).buttonStyle(.plain).foregroundStyle(SoriTheme.secondary)
                            .disabled(!canGenerate).padding(.top, 5)
                    }
                    if highlights.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("뚜렷한 강조 표현을 찾지 못했어요").font(.system(size: 17, weight: .medium))
                            Text("강조한 것으로 판단할 근거가 부족해 카드를 만들지 않았습니다. 전사문에서 강의 전체를 읽을 수 있어요.")
                                .font(.system(size: 15)).foregroundStyle(SoriTheme.secondary).lineSpacing(6)
                        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                            .background(SoriTheme.sidebar.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                    } else {
                        LazyVStack(spacing: 16) {
                            ForEach(highlights) { card in
                                LectureHighlightCard(card: card, segments: recording.segments, canPlay: canPlay, play: play)
                            }
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(isProcessing ? "강의의 흐름을 정리하고 있어요" : "강의의 중요한 내용을 모아보세요")
                            .font(.system(size: 22, weight: .medium)).tracking(-0.4)
                        Text(isProcessing
                             ? "정리가 끝나면 주제에 맞는 제목과 강조한 내용을 볼 수 있어요."
                             : "저장된 전사문으로 강의 제목과 강조한 내용을 정리합니다. 각 카드에서 근거가 된 발언을 다시 들을 수 있어요.")
                            .font(.system(size: 15)).foregroundStyle(SoriTheme.secondary).lineSpacing(6)
                        if !isProcessing {
                            Button(recording.generatedTitle == nil ? "핵심 요약 만들기" : "핵심 요약 다시 만들기") { generate() }
                                .buttonStyle(PrimaryButtonStyle()).disabled(!canGenerate).padding(.top, 8)
                            if !canGenerate {
                                Text("AI 연결 상태와 진행 중인 작업을 확인해 주세요.")
                                    .font(.system(size: 13)).foregroundStyle(SoriTheme.secondary)
                            }
                        }
                    }.padding(.vertical, 28)
                }
            }.frame(maxWidth: 740, alignment: .leading)
                .padding(.horizontal, 38).padding(.vertical, 30)
                .frame(maxWidth: .infinity, alignment: .center)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LectureHighlightCard: View {
    let card: LectureHighlight
    let segments: [TranscriptSegment]
    let canPlay: Bool
    let play: (TranscriptSegment) -> Void
    @State private var showEvidence = false

    private var firstSource: TranscriptSegment? {
        segments.first { segment in card.evidence.contains { $0.segmentID == segment.id } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(card.signal == .explicit ? "직접 강조한 내용" : "반복해서 설명한 내용")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(SoriTheme.secondary)
            Text(card.heading).font(.system(size: 19, weight: .semibold)).tracking(-0.25)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Text(card.summary).font(.system(size: 15)).lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            HStack(spacing: 18) {
                if let source = firstSource {
                    Button { play(source) } label: {
                        Label("\(TimeText.clock(source.start))에서 듣기", systemImage: "play.fill")
                    }.buttonStyle(.plain).disabled(!canPlay)
                        .accessibilityLabel("\(card.heading), \(TimeText.clock(source.start))에서 재생")
                }
                Spacer(minLength: 0)
                Button { showEvidence.toggle() } label: {
                    HStack(spacing: 6) {
                        Text(showEvidence ? "발언 접기" : "근거 발언")
                        Image(systemName: showEvidence ? "chevron.up" : "chevron.down")
                    }
                }.buttonStyle(.plain).foregroundStyle(SoriTheme.secondary)
                    .accessibilityValue(showEvidence ? "펼쳐짐" : "접힘")
            }.font(.system(size: 13, weight: .medium)).padding(.top, 5)
            if showEvidence {
                Rectangle().fill(SoriTheme.line).frame(height: 1).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(card.evidence.sorted { $0.segmentID < $1.segmentID }) { evidence in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("“\(evidence.quote)”").font(.system(size: 14)).lineSpacing(5)
                                .foregroundStyle(SoriTheme.secondary).textSelection(.enabled)
                            if let source = segments.first(where: { $0.id == evidence.segmentID }) {
                                Button("\(TimeText.clock(source.start))에서 확인") { play(source) }
                                    .font(.system(size: 13)).buttonStyle(.plain).disabled(!canPlay)
                            }
                        }
                    }
                }
            }
        }.foregroundStyle(SoriTheme.ink).padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(SoriTheme.line, lineWidth: 1).allowsHitTesting(false))
    }
}
