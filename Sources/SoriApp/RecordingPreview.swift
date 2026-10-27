import SwiftUI
import SoriCore

/// Snapshot fixtures only; no microphone, speech recognition or AI requests.
@MainActor enum RecordingPreview {
    static func configure(store: AppStore, arguments: [String]) {
        guard arguments.contains("--recording-only-preview"),
              let id = store.selectedID, let index = store.recordings.firstIndex(where: { $0.id == id }) else { return }
        store.recordings[index].recordingMode = .audioOnly
        store.recordings[index].status = .saved
        store.recordings[index].segments = []
        store.recordings[index].lectureHighlights = nil
        store.recordings[index].generatedTitle = nil
        store.recordings[index].work = nil
        store.recordings[index].isDemo = false
        store.recordings[index].title = "금융과 세계 경제 · 10.27 14:00"
        if arguments.contains("--recording-active-preview") {
            store.recordings[index].status = .recording
            store.recordingID = id
            store.audio.isRecording = true
            store.audio.recordingTime = 1234
        }
    }
}
