import Foundation
import SoriCore

/// Headless acceptance check: a completed synthetic file, local STT, and real text correction.
@MainActor
enum IntegrationCheck {
    static func run(store: AppStore, reportURL: URL) async -> Bool {
        var checks: [String] = []
        do {
            guard let repository = store.repository else { throw SoriError.message("No library") }
            let invalid = store.root.appendingPathComponent("not-audio.txt")
            try Data("This is not audio.".utf8).write(to: invalid)
            defer { try? FileManager.default.removeItem(at: invalid) }
            let beforeImport = store.recordings.count
            await store.importFiles([invalid])
            guard store.recordings.count == beforeImport, !AppStore.canImport(invalid), !store.isImporting else { throw SoriError.message("Invalid import left a phantom recording") }
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.root.path).filter { $0.hasPrefix(".import-") }
            guard leftovers.isEmpty else { throw SoriError.message("Import staging was not cleaned up") }
            store.errorMessage = nil
            checks.append("invalid file rejection without phantom recordings or partial files")
            let sample = AppResources.directory.appendingPathComponent("welcome.wav")
            await store.importFiles([sample])
            let started = ProcessInfo.processInfo.systemUptime
            let deadline = Date().addingTimeInterval(300)
            while store.processingID != nil || !store.queue.isEmpty {
                guard Date() < deadline else { throw SoriError.message("AI processing timed out") }
                try await Task.sleep(for: .milliseconds(200))
            }
            guard let recording = store.selected, recording.status == .ready, recording.segments.count >= 3,
                  recording.message == nil else { throw SoriError.message(store.selected?.message ?? store.errorMessage ?? "AI produced no transcript") }
            let processingSeconds = ProcessInfo.processInfo.systemUptime - started
            let outputDirectory = try repository.directory(for: recording)
            let originalURL = outputDirectory.appendingPathComponent("whisper-original.json")
            let original = try Transcript.parseWhisper(Data(contentsOf: originalURL), duration: recording.duration)
            guard !original.isEmpty, original.map(\.start) == recording.segments.map(\.start),
                  original.map(\.end) == recording.segments.map(\.end),
                  original.map(\.id) == recording.segments.map(\.id),
                  original.map(\.text) == recording.segments.map(\.originalText) else {
                throw SoriError.message("Text correction altered source intervals or lost original text")
            }
            let correctionsURL = outputDirectory.appendingPathComponent("codex-corrections.json")
            let corrected = try Transcript.applyCorrections(Data(contentsOf: correctionsURL), to: original)
            guard corrected == recording.segments else { throw SoriError.message("Saved text does not match the validated AI result") }
            guard recording.fullText.contains("좋은 생각"), recording.fullText.contains("꺼내 읽을 수 있도록") else {
                throw SoriError.message("Transcript is missing the beginning or end of the synthetic recording")
            }
            for (index, segment) in recording.segments.enumerated() {
                guard segment.start >= 0, segment.end > segment.start, segment.end <= recording.duration,
                      index == 0 || segment.start >= recording.segments[index - 1].end else {
                    throw SoriError.message("Sentence intervals are invalid")
                }
            }
            checks.append("completed 16 kHz WAV file batch-transcribed with local Whisper large-v3-turbo")
            checks.append("real Codex text correction through the existing ChatGPT login")
            checks.append("source text, segment identities and STT timestamps preserved through text correction")
            checks.append("beginning and end of the recording retained with ordered, bounded intervals")
            guard store.audio.duration > 20, !recording.waveform.isEmpty, recording.waveform.count <= 180 else { throw SoriError.message("Invalid audio duration or waveform") }
            store.audio.seek(6.5)
            guard abs(store.audio.currentTime - 6.5) < 0.05 else { throw SoriError.message("Seek failed") }
            store.audio.volume = 0
            store.audio.rate = 1.5
            store.audio.togglePlayback()
            try await Task.sleep(for: .milliseconds(500))
            guard store.audio.isPlaying, store.audio.currentTime > 6.9 else { throw SoriError.message("Playback clock did not advance") }
            store.audio.setLoop(start: 6, end: 6.4)
            try await Task.sleep(for: .milliseconds(750))
            // AVAudioPlayer can report a few milliseconds before the requested
            // seek point while its decoder aligns a frame.
            guard store.audio.isPlaying, store.audio.loopRange != nil, store.audio.currentTime >= 5.98, store.audio.currentTime < 6.5 else { throw SoriError.message("Sentence repeat failed: playing=\(store.audio.isPlaying), time=\(store.audio.currentTime), range=\(String(describing: store.audio.loopRange))") }
            store.audio.seek(6.4)
            guard store.audio.loopRange == nil else { throw SoriError.message("Seeking out of sentence did not clear repeat") }
            store.audio.setLoop(start: store.audio.duration - 0.3, end: store.audio.duration)
            store.audio.seek(store.audio.duration - 0.1)
            try await Task.sleep(for: .milliseconds(450))
            guard store.audio.isPlaying, store.audio.currentTime >= store.audio.duration - 0.35 else { throw SoriError.message("Last sentence did not repeat across EOF") }
            store.audio.clearLoop()
            store.audio.seek(store.audio.duration - 0.15)
            try await Task.sleep(for: .milliseconds(400))
            guard !store.audio.isPlaying, abs(store.audio.currentTime - store.audio.duration) < 0.1 else { throw SoriError.message("End of playback did not stop cleanly") }
            store.audio.volume = 1
            store.audio.seek(6.5)
            store.bookmark()
            guard store.selected?.bookmarks.last?.time == 6.5 else { throw SoriError.message("Bookmark failed") }
            store.bookmark()
            guard store.selected?.bookmarks.count == 1 else { throw SoriError.message("Repeated bookmark created a duplicate") }
            checks.append("audio decoding, bounded waveform, playback clock, speed, sentence repeat including EOF, seeking and bookmarks")
            if getuid() != 0 {
                let directory = try repository.directory(for: recording)
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
                do {
                    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
                    let saved = store.update(recording.id) { $0.notes = "저장 실패 후에도 보존되는 메모" }
                    guard !saved, store.unsavedIDs.contains(recording.id), store.selected?.notes == "저장 실패 후에도 보존되는 메모" else { throw SoriError.message("Unsaved changes were lost") }
                    guard await !store.prepareForTermination() else { throw SoriError.message("Quit accepted despite unsaved changes") }
                }
                guard store.retryUnsavedChanges(), store.unsavedIDs.isEmpty else { throw SoriError.message("Save retry failed after storage recovered") }
                store.errorMessage = nil
                checks.append("failed disk writes preserve edits, prevent quitting, and recover on retry")
            }
            let target = try repository.createProject(name: "검증 완료")
            store.projects.append(target)
            store.move(store.selected!, to: target)
            guard store.selected?.projectID == target.id else { throw SoriError.message("Folder move failed") }
            let reloaded = try LibraryRepository(root: store.root).load().recordings
            guard let saved = reloaded.first(where: { $0.id == recording.id }), saved.segments == recording.segments, saved.bookmarks.count == 1 else { throw SoriError.message("Persistence failed") }
            checks.append("folder move and complete reload from disk")
            let subtitles = Transcript.srt(saved.segments)
            guard subtitles.contains(" --> ") else { throw SoriError.message("SRT export failed") }
            try Data(subtitles.utf8).write(to: store.root.appendingPathComponent("acceptance.srt"))
            checks.append("subtitle export")
            let report: [String: Any] = ["passed": true, "checks": checks, "duration": saved.duration, "segments": saved.segments.count, "processingSeconds": processingSeconds, "scope": "batch-file-transcription-and-local-library", "model": URL(fileURLWithPath: store.settings.modelPath).lastPathComponent, "textCorrection": "codex-chatgpt", "timing": "whisper-segment-timestamps", "syntheticAudio": true]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
            return true
        } catch {
            let report: [String: Any] = ["passed": false, "checks": checks, "error": error.localizedDescription]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
            return false
        }
    }
}
