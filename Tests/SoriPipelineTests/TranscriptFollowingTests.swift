import AppKit
import XCTest
import SoriCore
@testable import SoriApp

@MainActor final class TranscriptFollowingTests: XCTestCase {
    private let recordingID = UUID()
    private let segments = (0..<24).map {
        TranscriptSegment(id: $0, start: Double($0 * 10), end: Double($0 * 10 + 8),
                          text: "가격과 수요량의 변화율을 비교합니다. 단위가 다른 상품도 같은 기준으로 읽을 수 있습니다.")
    }

    private func view(active: Int? = 12, time: Double = 120, request: Int = 0, query: String = "",
                      canPlay: Bool = true, segments: [TranscriptSegment]? = nil,
                      position: @escaping (TranscriptScrollDestination?) -> Void = { _ in },
                      play: @escaping (TranscriptSegment) -> Void = { _ in }) -> SelectableTranscriptView {
        .init(recordingID: recordingID, segments: segments ?? self.segments, original: false,
              textSize: 22, query: query, selectedSearchID: nil, activeID: active, playbackTime: time,
              followPlayback: true, scrollRequest: request, searchScrollRequest: 0,
              canPlay: canPlay, canEdit: true, play: play, togglePlayback: {}, isLooping: { _ in false },
              isBookmarked: { _ in false }, edit: { _ in }, repeatSegment: { _ in }, bookmark: { _ in }, copy: { _ in },
              playbackPositionChanged: position)
    }

    private func mount(_ value: SelectableTranscriptView, scrollerStyle: NSScroller.Style? = nil) -> (NSWindow, TranscriptScrollView, SelectableTranscriptView.Coordinator) {
        _ = NSApplication.shared
        let coordinator = value.makeCoordinator()
        let scroll = value.makeScrollView(coordinator: coordinator)
        if let scrollerStyle { scroll.scrollerStyle = scrollerStyle }
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 620, height: 340),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        coordinator.update(value, scroll: scroll)
        scroll.layoutSubtreeIfNeeded()
        return (window, scroll, coordinator)
    }

    private func move(_ scroll: TranscriptScrollView, to y: CGFloat) {
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func testViewportReportsBothDirectionsAndReturnResumesWithoutSeeking() async throws {
        let below = expectation(description: "현재 문장이 화면 아래에 있음")
        let above = expectation(description: "현재 문장이 화면 위에 있음")
        let returned = expectation(description: "돌아오면 버튼 숨김")
        var played: [Int] = []
        var positions: [TranscriptScrollDestination?] = []
        let callback: (TranscriptScrollDestination?) -> Void = { value in
            positions.append(value)
            switch value { case .below: below.fulfill(); case .above: above.fulfill(); case nil: returned.fulfill() }
        }
        let initial = view(position: callback, play: { played.append($0.id) })
        let (window, scroll, coordinator) = mount(initial)
        defer { coordinator.stopObserving(); window.close() }
        XCTAssertNil(coordinator.playbackScrollDestination)

        move(scroll, to: 0)
        await fulfillment(of: [below], timeout: 2)
        XCTAssertTrue(scroll.followPaused)
        let origin = scroll.contentView.bounds.origin
        coordinator.update(view(active: 13, time: 130, position: callback), scroll: scroll)
        XCTAssertEqual(scroll.contentView.bounds.origin, origin, "재생이 진행돼도 직접 읽는 위치를 유지")

        let text = try XCTUnwrap(scroll.documentView as? TranscriptTextView)
        move(scroll, to: text.bounds.height - scroll.contentSize.height)
        await fulfillment(of: [above], timeout: 2)
        text.selectAll(nil)
        coordinator.update(view(active: 13, time: 130, request: 1, position: callback,
                                play: { played.append($0.id) }), scroll: scroll)
        await fulfillment(of: [returned], timeout: 2)
        XCTAssertFalse(scroll.followPaused)
        XCTAssertFalse(text.hasSelection)
        XCTAssertTrue(played.isEmpty, "현재 위치로 이동은 오디오를 다시 재생하거나 seek하지 않음")
        XCTAssertEqual(positions, [.below, .above, nil])

        coordinator.update(view(active: 20, time: 200, request: 1), scroll: scroll)
        XCTAssertNil(coordinator.playbackScrollDestination, "다음 문장부터 자동 따라가기 재개")
        XCTAssertFalse(window.isVisible)
    }

    func testSearchUnplayableAudioAndGapUseTheRightVisibility() {
        let initial = view()
        let (window, scroll, coordinator) = mount(initial)
        defer { coordinator.stopObserving(); window.close() }
        move(scroll, to: 0)
        XCTAssertEqual(coordinator.playbackScrollDestination, .below)
        coordinator.update(view(query: "가격"), scroll: scroll)
        XCTAssertNil(coordinator.playbackScrollDestination, "검색 결과를 읽을 때는 표시하지 않음")
        coordinator.update(view(canPlay: false), scroll: scroll)
        XCTAssertNil(coordinator.playbackScrollDestination)
        coordinator.update(view(active: nil, time: 129), scroll: scroll)
        XCTAssertEqual(coordinator.playbackScrollDestination, .below, "문장 사이 무음에서도 직전 문장으로 복귀 가능")
    }

    func testLongSentenceAndWindowResizeUseRenderedVisibility() throws {
        let long = [TranscriptSegment(id: 0, start: 0, end: 100,
                    text: String(repeating: "긴 설명도 문장이 화면에 보이는 동안 버튼을 띄우지 않습니다. ", count: 35))]
        let initial = view(active: 0, time: 10, segments: long)
        let (window, scroll, coordinator) = mount(initial)
        defer { coordinator.stopObserving(); window.close() }
        move(scroll, to: 200)
        XCTAssertNil(coordinator.playbackScrollDestination)
        window.setContentSize(NSSize(width: 500, height: 240))
        scroll.layoutSubtreeIfNeeded()
        XCTAssertNil(coordinator.playbackScrollDestination)
    }

    func testAnimatedFollowMovesThroughIntermediatePositionsAndFinishesAtTarget() async {
        let (window, scroll, coordinator) = mount(view(), scrollerStyle: .legacy)
        defer { coordinator.stopObserving(); window.close() }
        let origin = scroll.contentView.bounds.origin
        let destination = NSPoint(x: origin.x, y: origin.y + 240)
        let finished = expectation(description: "부드러운 따라가기 완료")
        var positions: [CGFloat] = []
        let observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: .main) { _ in positions.append(scroll.contentView.bounds.origin.y) }
        defer { NotificationCenter.default.removeObserver(observer) }
        var didFinish = false
        scroll.viewportChanged = {
            if !didFinish, !scroll.isFollowingPlayback, abs(scroll.contentView.bounds.origin.y - destination.y) < 1 {
                didFinish = true; finished.fulfill()
            }
        }
        scroll.scrollToPlayback(destination, animated: true)
        XCTAssertTrue(scroll.isFollowingPlayback)
        XCTAssertNil(coordinator.playbackScrollDestination, "자동 이동 중에는 복귀 버튼이 깜빡이지 않음")
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertGreaterThan(positions.filter { $0 > origin.y + 1 && $0 < destination.y - 1 }.count, 2)
        // AppKit aligns clip bounds to backing pixels; fractional positions can
        // differ by one pixel between a layout pass and an animation tick.
        let pixel = 1 / window.backingScaleFactor
        XCTAssertTrue(zip(positions, positions.dropFirst()).allSatisfy { $0 <= $1 + pixel + 0.01 },
                      "역방향 이동이 한 픽셀을 넘지 않아야 함: \(positions)")
        XCTAssertEqual(scroll.contentView.bounds.origin.y, destination.y, accuracy: 1)
    }

    func testManualScrollCancelsInFlightAnimationAtCurrentPosition() async throws {
        let (window, scroll, coordinator) = mount(view())
        defer { coordinator.stopObserving(); window.close() }
        let origin = scroll.contentView.bounds.origin
        let interrupted = expectation(description: "사용자 스크롤 즉시 중단")
        var stoppedAt: CGFloat?
        let observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: .main) { _ in
                let y = scroll.contentView.bounds.origin.y
                if stoppedAt == nil, y > origin.y + 1 {
                    stoppedAt = y
                    NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
                    interrupted.fulfill()
                }
            }
        defer { NotificationCenter.default.removeObserver(observer) }
        scroll.scrollToPlayback(NSPoint(x: origin.x, y: origin.y + 240), animated: true)
        await fulfillment(of: [interrupted], timeout: 3)
        XCTAssertFalse(scroll.isFollowingPlayback)
        XCTAssertTrue(scroll.followPaused)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(scroll.contentView.bounds.origin.y, try XCTUnwrap(stoppedAt), accuracy: 1)
    }
}
