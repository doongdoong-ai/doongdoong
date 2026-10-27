import AppKit
import AVFoundation
import Observation
import SoriCore
import SoriSpeech
import DoongdoongAI
import DoongdoongTranscription
import UniformTypeIdentifiers

@Observable @MainActor
final class AppStore {
    let settings: AppSettings
    let audio = AudioEngine()
    var projects: [Project] = []
    var recordings: [Recording] = []
    var selectedID: UUID?
    var selectedProjectID: UUID?
    var search = ""
    var transcriptSearch = ""
    var errorMessage: String?
    var toast: String?
    var showSettings = false
    var settingsSection: SettingsSection = .speech
    private enum ConnectionIntent { case recording, process([(id: UUID, summaryOnly: Bool)]) }
    private var connectionIntent: ConnectionIntent?
    private var continueAfterConnectionDismissal = false
    var showRecordingDestination = false
    var librarySearchRequested = false
    var recordingID: UUID?
    var processingID: UUID?
    var queue: [UUID] = []
    private var lectureOnlyIDs: Set<UUID> = []
    var processingProgress: ProcessingProgress?
    var processingStartedAt: Date?
    var processingEstimateStartedUptime: TimeInterval?
    var processingIssues: Set<ProcessingProgress.Step> = []
    var processingCompletedSteps: Set<ProcessingProgress.Step> = []
    var processingSummaryOnly = false
    var isImporting = false
    var isInstalling = false
    var isStartingRecording = false
    private(set) var isFinalizingRecording = false
    private(set) var importingIDs: Set<UUID> = []
    private(set) var unsavedIDs: Set<UUID> = []
    var focusMode = false
    var showNotes = false
    var followPlayback = true
    var showOriginal = false
    let root: URL
    private(set) var repository: LibraryRepository?
    private var liveTranscription: LocalRecordingTranscription?
    private var finalizingTranscription: LocalRecordingTranscription?
    private var pipelineTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var importRunner: ProcessRunner?
    private var finalizingID: UUID?
    private var isTerminating = false
    private var isAddingDemo = false
    private(set) var isSleeping = false
    private(set) var isPreparingForSleep = false
    private(set) var recoveringIDs: Set<UUID> = []
    private var sleepTask: Task<Void, Never>?
    private var sleepGeneration = UUID()
    private var wakeResumeIDs: [UUID] = []
    private let recognizer: any SpeechRecognizer
    private let textProvider: (any TextGenerationProvider)?

    init(root explicitRoot: URL? = nil, settings: AppSettings? = nil,
         recognizer: any SpeechRecognizer = LocalTranscription.engine, textProvider: (any TextGenerationProvider)? = nil) {
        self.settings = settings ?? AppSettings()
        self.recognizer = recognizer; self.textProvider = textProvider
        let args = ProcessInfo.processInfo.arguments
        if let explicitRoot {
            root = explicitRoot
        } else if let index = args.firstIndex(of: "--library"), args.count > index + 1 {
            root = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        } else {
            let music = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music", isDirectory: true)
            let branded = music.appendingPathComponent("둥둥이", isDirectory: true)
            let previous = music.appendingPathComponent("붕붕이", isDirectory: true)
            let legacy = music.appendingPathComponent("Sori", isDirectory: true)
            root = [branded, previous, legacy].first { FileManager.default.fileExists(atPath: $0.path) } ?? branded
        }
        do {
            let repo = try LibraryRepository(root: root); repository = repo
            let loaded = try repo.load(); projects = loaded.projects; recordings = loaded.recordings
            if projects.isEmpty { projects = [try repo.createProject(name: "받은 녹음")] }
            selectedProjectID = projects.first?.id
            if !repo.warnings.isEmpty { errorMessage = "일부 폴더를 읽지 못했습니다. 원본 파일은 그대로 보관됩니다.\n" + repo.warnings.joined(separator: "\n") }
        } catch { errorMessage = error.localizedDescription }
        audio.onRecordingError = { [weak self] error in
            guard let self else { return }
            if let id = self.recordingID { self.update(id) {
                $0.duration = self.audio.recordingTime; $0.status = .failed; $0.message = error
                $0.work = .init(kind: .recording, state: .interrupted, cause: self.isSleeping ? .sleep : .unexpected)
            } }
            let live = self.liveTranscription; self.liveTranscription = nil
            Task { await live?.finish() }
            self.recordingID = nil; self.errorMessage = error
        }
        audio.onPlaybackError = { [weak self] error in self?.errorMessage = error }
        if let first = recordings.first(where: { $0.work?.state == .interrupted }) ?? recordings.first { select(first.id) }
        if explicitRoot == nil, args.contains("--demo") { Task { await addDemo() } }
    }

    var selected: Recording? { recordings.first { $0.id == selectedID } }
    var visibleRecordings: [Recording] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return recordings.filter {
            if query.isEmpty { return $0.projectID == selectedProjectID }
            return $0.title.localizedCaseInsensitiveContains(query) || $0.fullText.localizedCaseInsensitiveContains(query) || $0.notes.localizedCaseInsensitiveContains(query)
        }.sorted { $0.createdAt > $1.createdAt }
    }
    var currentProjectName: String { projects.first { $0.id == selected?.projectID }?.name ?? "라이브러리" }
    var totalDuration: Double { recordings.reduce(0) { $0 + $1.duration } }
    var busy: Bool { audio.isRecording || processingID != nil || isImporting || isStartingRecording || isFinalizingRecording || isInstalling || isAddingDemo }
    func isFinalizing(_ id: UUID) -> Bool { finalizingID == id }
    func progress(for id: UUID) -> ProcessingProgress? {
        if let processingID { return processingID == id ? processingProgress : nil }
        return finalizingID == id ? processingProgress : nil
    }
    func isSummaryOnly(_ id: UUID) -> Bool {
        if processingID == id { return processingSummaryOnly }
        return lectureOnlyIDs.contains(id) || recordings.first(where: { $0.id == id })?.work?.kind == .summary
    }
    func updateProgress(_ value: ProcessingProgress, for id: UUID) {
        guard processingID.map({ $0 == id }) ?? (finalizingID == id) else { return }
        guard !isSleeping, !isPreparingForSleep else { return }
        if processingProgress?.stage.step != value.stage.step {
            processingEstimateStartedUptime = nil
        }
        // Connection checks are not inference time; retries within the same step
        // must not restart the estimate or send the bar backwards.
        if value.estimatedDuration != nil, processingEstimateStartedUptime == nil {
            processingEstimateStartedUptime = ProcessInfo.processInfo.systemUptime
        }
        if recordings.first(where: { $0.id == id })?.work?.step != value.stage.step {
            update(id) { $0.work?.step = value.stage.step }
        }
        if processingStartedAt == nil { processingStartedAt = Date() }
        if let previous = processingProgress, previous.stage.step != value.stage.step,
           !processingIssues.contains(previous.stage.step) {
            processingCompletedSteps.insert(previous.stage.step)
        }
        if value.issue { processingIssues.insert(value.stage.step); processingCompletedSteps.remove(value.stage.step) }
        processingProgress = value
    }

    func canModify(_ id: UUID) -> Bool {
        !isTerminating && !isSleeping && !isPreparingForSleep && !recoveringIDs.contains(id) && recordings.contains(where: { $0.id == id }) && id != recordingID && id != finalizingID && id != processingID && !importingIDs.contains(id) && !queue.contains(id)
    }

    func canTranscribe(_ id: UUID) -> Bool {
        settings.transcriptionReady && canModify(id)
    }

    func canOrganizeLecture(_ id: UUID) -> Bool {
        settings.analysisEnabled && canModify(id) && recordings.contains { $0.id == id && !$0.segments.isEmpty }
    }

    func canRename(_ id: UUID) -> Bool {
        canModify(id) && recordings.contains { $0.id == id && ($0.generatedTitle != nil || $0.recordsAudioOnly) }
    }

    func renameRecording(_ id: UUID, title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canRename(id), !clean.isEmpty, clean.count <= 120 else { return }
        update(id) { $0.title = clean; $0.titleEditedByUser = true }
    }

    private func apply(_ lecture: LectureInsights, to recording: inout Recording) {
        recording.generatedTitle = lecture.title
        if recording.titleEditedByUser != true { recording.title = lecture.title }
        recording.lectureHighlights = lecture.highlights
    }

    func select(_ id: UUID?) {
        if let item = recordings.first(where: { $0.id == id }) { selectedProjectID = item.projectID }
        guard selectedID != id else { return }
        selectedID = id; transcriptSearch = ""; followPlayback = true
        audio.stopPlayback()
        guard let item = selected, item.id != recordingID, item.id != finalizingID, !importingIDs.contains(item.id), !recoveringIDs.contains(item.id), !(item.work?.kind == .recording && item.audioFileName == nil), let repository else { return }
        do {
            let url = try repository.audioURL(for: item)
            if FileManager.default.fileExists(atPath: url.path) { try audio.load(url) }
        } catch { errorMessage = error.localizedDescription }
    }

    func selectProject(_ project: UUID) {
        guard projects.contains(where: { $0.id == project }) else { return }
        selectedProjectID = project; search = ""
        if !visibleRecordings.contains(where: { $0.id == selectedID }) { select(visibleRecordings.first?.id) }
    }

    func createProject(_ name: String) {
        do {
            guard let repository else { return }
            let project = try repository.createProject(name: name)
            projects.append(project); selectProject(project.id)
        } catch { errorMessage = error.localizedDescription }
    }
    func renameProject(_ project: Project, name: String) {
        guard !busy else { return }
        do {
            guard let repository else { return }
            let renamed = try repository.renameProject(project, to: name)
            if let index = projects.firstIndex(where: { $0.id == project.id }) { projects[index] = renamed }
        } catch { errorMessage = error.localizedDescription }
    }
    func deleteProject(_ project: Project) {
        guard !busy, projects.count > 1 else { return }
        do {
            guard let repository else { return }
            try repository.removeEmptyProject(project); projects.removeAll { $0.id == project.id }
            if selectedProjectID == project.id, let next = projects.first { selectProject(next.id) }
        } catch { errorMessage = error.localizedDescription }
    }

    func requestRecording() {
        guard !audio.isRecording, !isStartingRecording, !isFinalizingRecording, !isTerminating, !isSleeping, !isPreparingForSleep, repository != nil else { return }
        if needsAIConnection {
            connectionIntent = .recording
            settings.presentConnectionSetup()
            return
        }
        showRecordingDestination = true
    }

    private var needsAIConnection: Bool { settings.analysisEnabled && textProvider == nil && !settings.analysisReady }

    func finishConnectionSetup() {
        guard settings.selectedModel != nil else { return }
        continueAfterConnectionDismissal = true
        settings.dismissConnectionSetup()
    }
    func connectionSetupDismissed() {
        let intent = connectionIntent
        connectionIntent = nil
        guard continueAfterConnectionDismissal else { return }
        continueAfterConnectionDismissal = false
        switch intent {
        case .recording: requestRecording()
        case .process(let jobs):
            for job in jobs { enqueue(job.id, lectureOnly: job.summaryOnly) }
        case nil: break
        }
    }
    func openConnectionSettings() {
        connectionIntent = nil; continueAfterConnectionDismissal = false
        settings.dismissConnectionSetup()
        settingsSection = .providers; showSettings = true
    }

    func startRecording(in projectID: UUID) async {
        guard !audio.isRecording, !isStartingRecording, !isFinalizingRecording, !isTerminating, !isSleeping, !isPreparingForSleep, let repository else { return }
        isStartingRecording = true; defer { isStartingRecording = false }
        guard await audio.requestMicrophone() else {
            errorMessage = "마이크 접근이 허용되지 않았습니다. 시스템 설정 → 개인정보 보호 및 보안 → 마이크에서 둥둥이를 허용해 주세요."
            return
        }
        guard !isTerminating, !isSleeping, !isPreparingForSleep else { return }
        do {
            guard let project = projects.first(where: { $0.id == projectID }) else {
                throw SoriError.message("녹음을 저장할 폴더가 없습니다. 폴더를 먼저 만들어 주세요.")
            }
            let title = Date().formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute()) + " 녹음"
            var recording = try repository.createRecording(project: project, title: title)
            recording.recordingMode = .lecture
            recording.status = .recording
            recording.work = .init(kind: .recording, state: .running)
            recordings.insert(recording, at: 0)
            do {
                try repository.save(recording)
                try LocalTranscription.prepareRecording(directory: repository.directory(for: recording))
                try audio.startRecording(to: repository.audioURL(for: recording))
            } catch {
                update(recording.id) { $0.status = .failed; $0.message = error.localizedDescription }
                throw error
            }
            recordingID = recording.id
            if settings.transcriptionReady {
                let live = LocalRecordingTranscription(audio: try repository.audioURL(for: recording),
                    directory: try repository.directory(for: recording), configuration: settings.transcriptionConfiguration)
                let id = recording.id
                live.onIssue = { [weak self] message in
                    guard let self, self.recordingID == id else { return }
                    self.update(id) { $0.message = message }
                }
                liveTranscription = live; live.start()
            }
            search = ""; selectedProjectID = project.id
            selectedID = recording.id
        } catch { errorMessage = error.localizedDescription }
    }

    @discardableResult func stopRecording(enqueueForTranscription: Bool = true) async -> Bool {
        guard !isFinalizingRecording, let id = recordingID, let recording = recordings.first(where: { $0.id == id }), let repository else { return true }
        // Flush the editor before its workspace leaves the view tree, including
        // stops initiated by the menu or the application termination path.
        NotificationCenter.default.post(name: Notification.Name("BungBungiWillSave"), object: nil)
        if recordings.first(where: { $0.id == id })?.notes.isEmpty == false { showNotes = true }
        isFinalizingRecording = true; finalizingID = id
        // The live ASR request can still be finishing when the microphone stops.
        // Show that drain explicitly rather than briefly returning to an empty view.
        if processingID == nil {
            processingProgress = nil; processingStartedAt = Date(); processingIssues = []; processingCompletedSteps = []; processingSummaryOnly = false
            if !recording.recordsAudioOnly {
                updateProgress(.init(stage: .finishingRecording, detail: "녹음을 저장하고 처리 중인 음성 구간을 마무리합니다."), for: id)
            }
        }
        defer {
            isFinalizingRecording = false; finalizingID = nil; finalizingTranscription = nil
            if processingID == nil { processingProgress = nil; processingStartedAt = nil }
        }
        let duration = audio.finishRecording(); recordingID = nil
        let live = liveTranscription; liveTranscription = nil
        finalizingTranscription = live
        let saved = update(id) {
            $0.duration = duration
            if $0.recordsAudioOnly {
                $0.status = .saved; $0.work = nil; $0.message = nil
            } else {
                $0.status = .queued
                $0.work = .init(kind: .transcription,
                    state: enqueueForTranscription && !self.isTerminating ? .queued : .interrupted,
                    cause: self.isTerminating ? .appClosed : enqueueForTranscription ? nil : .userStopped)
            }
        }
        await live?.finish(cancel: isTerminating)
        do {
            let url = try repository.audioURL(for: recording)
            let info = try await Task.detached { try AudioEngine.inspect(url) }.value
            let inspectedSaved = update(id) { $0.duration = info.duration; $0.waveform = info.waveform }
            if selectedID == id { do { try audio.load(url) } catch { errorMessage = error.localizedDescription } }
            if info.duration < 0.3 { update(id) { $0.status = .failed; $0.message = "녹음이 너무 짧습니다. 1초 이상 녹음해 주세요." } }
            else if saved && inspectedSaved && !recording.recordsAudioOnly && enqueueForTranscription && settings.transcriptionReady && !isTerminating {
                finalizingID = nil; enqueue(id)
            }
            else if saved && inspectedSaved && recording.recordsAudioOnly && !isTerminating { notify("녹음을 저장했습니다") }
        } catch { update(id) { $0.status = .failed; $0.message = error.localizedDescription } }
        return !unsavedIDs.contains(id)
    }

    func importAudio() {
        guard !isImporting, !isTerminating, !isSleeping, !isPreparingForSleep, repository != nil else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = true; panel.message = "녹음 파일을 작업 폴더에 복사합니다."
        if panel.runModal() == .OK { let urls = panel.urls; Task { await importFiles(urls) } }
    }

    static func canImport(_ url: URL) -> Bool {
        guard url.isFileURL, let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey]), values.isRegularFile == true else { return false }
        let type = values.contentType ?? UTType(filenameExtension: url.pathExtension)
        if let type, type.conforms(to: .audio) || type.conforms(to: .movie) { return true }
        return ["wav", "wave", "mp3", "m4a", "aac", "aif", "aiff", "caf", "flac", "ogg", "opus", "mp4", "mov", "m4v", "webm", "mkv"].contains(url.pathExtension.lowercased())
    }

    func importFiles(_ urls: [URL]) async {
        guard !isImporting, !isTerminating, !isSleeping, !isPreparingForSleep, !urls.isEmpty, let repository else { return }
        guard let project = projects.first(where: { $0.id == selectedProjectID }) ?? projects.first else {
            errorMessage = "파일을 저장할 폴더를 먼저 만들어 주세요."; return
        }
        guard FileManager.default.isExecutableFile(atPath: settings.ffmpegPath) else {
            errorMessage = "파일 가져오기를 준비하지 못했습니다. 고급 설정에서 파일 변환 프로그램의 위치를 확인해 주세요."; return
        }
        isImporting = true; defer { isImporting = false }
        var failures: [String] = []
        for source in urls {
            if isTerminating || isSleeping || Task.isCancelled { break }
            var importedID: UUID?
            let staging = root.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
            let accessed = source.startAccessingSecurityScopedResource()
            defer {
                if accessed { source.stopAccessingSecurityScopedResource() }
                try? FileManager.default.removeItem(at: staging)
                if let importedID { importingIDs.remove(importedID) }
                importRunner = nil
            }
            do {
                guard Self.canImport(source) else { throw SoriError.message("지원되는 오디오·동영상 파일이 아닙니다.") }
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
                let partial = staging.appendingPathComponent("audio.wav")
                let runner = ProcessRunner(); importRunner = runner
                try await runner.run(executable: URL(fileURLWithPath: settings.ffmpegPath), arguments: [
                    "-nostdin", "-hide_banner", "-loglevel", "error", "-i", source.path,
                    "-vn", "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", partial.path
                ], directory: staging, log: staging.appendingPathComponent("import.log"))
                try Task.checkCancellation()
                if isTerminating || isSleeping { throw CancellationError() }
                let info = try await Task.detached { try AudioEngine.inspect(partial) }.value
                try Task.checkCancellation()
                guard info.duration >= 0.3 else { throw SoriError.message("오디오가 너무 짧습니다. 1초 이상의 파일을 선택해 주세요.") }
                if isTerminating || isSleeping { throw CancellationError() }
                let recording = try repository.createRecording(project: project, title: source.deletingPathExtension().lastPathComponent)
                importedID = recording.id; importingIDs.insert(recording.id); recordings.insert(recording, at: 0)
                let destination = try repository.audioURL(for: recording)
                try FileManager.default.moveItem(at: partial, to: destination)
                let saved = update(recording.id) { $0.duration = info.duration; $0.waveform = info.waveform }
                importingIDs.remove(recording.id)
                search = ""; select(recording.id)
                if saved && settings.transcriptionReady { enqueue(recording.id) }
            } catch {
                let message = error is CancellationError ? "가져오기를 중지했습니다. 원본 파일은 그대로 보관되어 있습니다."
                    : "파일을 가져오지 못했습니다. 재생 가능한 오디오인지, 저장 공간과 폴더 권한을 확인해 주세요."
                if let importedID { update(importedID) { $0.status = .failed; $0.message = message } }
                if !(error is CancellationError) { failures.append("\(source.lastPathComponent): \(message)") }
            }
        }
        if !failures.isEmpty { errorMessage = failures.prefix(5).joined(separator: "\n\n") + (failures.count > 5 ? "\n외 \(failures.count - 5)개 파일을 가져오지 못했습니다." : "") }
    }

    // Explicitly injected providers do not depend on Codex installation or
    // model discovery. Connection failures are checked by the pipeline.
    private var analysisReady: Bool {
        settings.analysisEnabled && (textProvider != nil || settings.analysisReady)
    }

    func enqueue(_ id: UUID, lectureOnly: Bool = false) {
        guard !isTerminating, !isSleeping, !isPreparingForSleep, !recoveringIDs.contains(id), recordings.contains(where: { $0.id == id }), id != recordingID, id != finalizingID, id != processingID, !importingIDs.contains(id), !queue.contains(id) else { return }
        if let item = recordings.first(where: { $0.id == id }), item.work?.kind == .recording,
           item.audioFileName == nil || item.duration <= 0 { return }
        if needsAIConnection {
            // Imported batches and a recording just stopped are saved, not silently
            // left looking queued while connection setup is open or dismissed.
            if let item = recordings.first(where: { $0.id == id }), item.status == .queued,
               item.segments.isEmpty, item.work?.state != .interrupted {
                guard update(id, { $0.status = .saved; $0.work = nil }) else { return }
            }
            var jobs: [(id: UUID, summaryOnly: Bool)] = []
            if case .process(let pending) = connectionIntent { jobs = pending.filter { $0.id != id } }
            jobs.append((id, lectureOnly)); connectionIntent = .process(jobs)
            settings.presentConnectionSetup()
            return
        }
        // Preserve existing results when the local AI dependencies are unavailable.
        guard lectureOnly ? analysisReady : settings.transcriptionReady else {
            errorMessage = lectureOnly ? settings.aiConnectionMessage : settings.transcriptionUnavailableReason
            return
        }
        if lectureOnly, !recordings.contains(where: { $0.id == id && !$0.segments.isEmpty }) { return }
        guard update(id, { $0.status = .queued; $0.message = nil; $0.work = .init(kind: lectureOnly ? .summary : .transcription) }) else { return }
        if lectureOnly { lectureOnlyIDs.insert(id) }
        queue.append(id); runNext()
    }

    private func runNext() {
        guard !isTerminating, !isSleeping, !isPreparingForSleep, processingID == nil, !queue.isEmpty else { return }
        let id = queue.removeFirst()
        guard update(id, { $0.work?.state = .running; $0.work?.cause = nil }) else { return }
        processingID = id
        let continuedFromRecording = processingProgress?.stage == .finishingRecording
        processingProgress = nil
        if !continuedFromRecording { processingStartedAt = Date() }
        processingEstimateStartedUptime = nil
        processingIssues = []; processingCompletedSteps = []
        let lectureOnly = lectureOnlyIDs.remove(id) != nil
        processingSummaryOnly = lectureOnly
        updateProgress(.init(stage: lectureOnly ? .analysis : .preparing,
            detail: lectureOnly ? "저장된 전사문에서 핵심 요약을 준비합니다." : "녹음 길이와 저장된 전사 구간을 확인합니다."), for: id)
        let configuration = settings.transcriptionConfiguration
        let provider = settings.analysisEnabled ? (textProvider ?? settings.makeTextProvider()) : nil
        pipelineTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.processingID = nil; self.pipelineTask = nil; self.processingProgress = nil
                self.processingStartedAt = nil
                self.processingEstimateStartedUptime = nil; self.runNext()
            }
            do {
                guard let item = self.recordings.first(where: { $0.id == id }), let repository = self.repository else { return }
                let directory = try repository.directory(for: item)
                if lectureOnly {
                    guard self.update(id, { $0.status = .polishing }) else { return }
                    self.processingCompletedSteps = []
                    guard let provider else {
                        throw SoriError.message("AI 연결 확인을 마친 뒤 다시 시도해 주세요. 녹음은 보관되어 있습니다.")
                    }
                    let lecture = try await TranscriptionPipeline.organize(segments: item.segments, directory: directory,
                        provider: provider,
                        onProgress: { [weak self] value in self?.updateProgress(value, for: id) })
                    try Task.checkCancellation()
                    self.updateProgress(.init(stage: .saving, detail: "제목과 핵심 요약을 보관함에 저장합니다."), for: id)
                    guard self.update(id, { self.apply(lecture, to: &$0); $0.status = $0.completedStatus; $0.message = nil; $0.work = nil }) else { return }
                    self.notify("핵심 요약을 정리했습니다")
                    return
                }
                var audio = try repository.audioURL(for: item)
                if item.audioFileName == nil,
                   let recovered = try await LocalTranscription.recoverInterrupted(audio: audio, directory: directory, language: configuration.language) {
                    guard self.update(id, { $0.audioFileName = recovered.lastPathComponent }) else { throw SoriError.message("복구한 음성의 위치를 저장하지 못했습니다.") }
                    audio = recovered
                    if self.selectedID == id { try? self.audio.load(recovered) }
                }
                let source = audio
                let info = try await Task.detached { try AudioEngine.inspect(source) }.value
                try Task.checkCancellation()
                guard self.update(id, { $0.status = .transcribing; $0.duration = info.duration; $0.waveform = info.waveform }) else {
                    self.update(id) { $0.status = $0.segments.isEmpty ? .queued : $0.completedStatus; $0.message = "저장 공간을 확인한 뒤 다시 시도해 주세요. 녹음은 보관되어 있습니다." }
                    return
                }
                let result = try await TranscriptionPipeline.transcribe(
                    audio: audio, directory: directory, duration: info.duration, configuration: configuration,
                    recognizer: self.recognizer, provider: provider,
                    onProgress: { [weak self] value in self?.updateProgress(value, for: id) },
                    onReviewed: { segments in
                        // Keep any previous user edits until a complete replacement is ready.
                        guard self.update(id, {
                            if $0.segments.isEmpty { $0.segments = segments }
                            $0.status = .polishing
                        }) else {
                            throw SoriError.message("전사문을 저장하지 못했습니다. 저장 공간을 확인한 뒤 다시 시도해 주세요.")
                        }
                    })
                try Task.checkCancellation()
                self.updateProgress(.init(stage: .saving, detail: "전사문과 재생 위치를 보관함에 저장합니다."), for: id)
                switch result {
                case .noSpeech:
                    guard let previous = self.recordings.first(where: { $0.id == id }) else { return }
                    // Reprocessing must be able to replace a hallucinated transcript, while
                    // preserving the earlier result and any manual edits in the task folder.
                    try repository.archiveTranscript(previous)
                    guard self.update(id, {
                        $0.segments = []; $0.reviewRanges = nil
                        $0.lectureHighlights = nil
                        $0.status = .noSpeech; $0.work = nil
                        $0.message = previous.segments.isEmpty ? nil : "이전 텍스트도 작업 폴더에 보관했습니다."
                    }) else { return }
                    self.notify("감지된 음성이 없어요 · \(item.title)")
                case let .transcribed(segments, lecture, warning, reviewRanges):
                    if !item.segments.isEmpty, item.segments != segments {
                        // Retain prior manual corrections when explicit reprocessing replaces text.
                        try repository.archiveTranscript(item)
                    }
                    guard self.update(id, {
                        $0.segments = segments; $0.reviewRanges = reviewRanges; $0.status = $0.completedStatus; $0.message = warning
                        $0.work = nil
                        $0.lectureHighlights = nil
                        if let lecture { self.apply(lecture, to: &$0) }
                    }) else { return }
                    let title = self.recordings.first(where: { $0.id == id })?.title ?? item.title
                    self.notify(!reviewRanges.isEmpty ? "음성을 확인할 부분이 있어요 · \(title)" : warning == nil ? "정리 완료 · \(title)" : "텍스트를 저장했습니다 · \(title)")
                }
            } catch {
                self.update(id) {
                    $0.status = $0.segments.isEmpty ? .failed : $0.completedStatus
                    if $0.work?.state != .interrupted { $0.work?.interrupt(error is CancellationError ? .userStopped : .unexpected) }
                    $0.message = error is CancellationError ? nil : error.localizedDescription
                }
            }
        }
    }

    func cancelProcessing(_ id: UUID) {
        if wakeResumeIDs.contains(id) {
            wakeResumeIDs.removeAll { $0 == id }
            update(id) { $0.work?.interrupt(.userStopped) }
        }
        if processingID == id {
            update(id) { $0.work?.interrupt(.userStopped) }
            pipelineTask?.cancel()
        } else if queue.contains(id) {
            queue.removeAll { $0 == id }; lectureOnlyIDs.remove(id)
            update(id) { $0.status = $0.segments.isEmpty ? .queued : $0.completedStatus; $0.work?.interrupt(.userStopped); $0.message = nil }
        }
    }

    /// The notification handler calls this synchronously before returning to macOS.
    /// Only the bounded metadata flush is synchronous; inference teardown is async.
    func systemWillSleep() {
        guard !isTerminating, !isSleeping else { return }
        isSleeping = true
        settings.cancelSpeechPreparation()
        NotificationCenter.default.post(name: Notification.Name("BungBungiWillSave"), object: nil)
        audio.pauseForSleep()
        if let id = recordingID {
            update(id) { $0.duration = self.audio.recordingTime; $0.work?.interrupt(.sleep); $0.message = nil }
        }
        // Preserve the active item first, then its queue order, across repeated sleeps.
        for id in [processingID, finalizingID].compactMap({ $0 }) + queue where !wakeResumeIDs.contains(id) {
            if recordings.first(where: { $0.id == id })?.work?.cause != .userStopped { wakeResumeIDs.append(id) }
        }
        for id in wakeResumeIDs { update(id) { $0.work?.interrupt(.sleep) } }
        queue.removeAll(); lectureOnlyIDs.removeAll()
        pipelineTask?.cancel(); importRunner?.cancel()
        let live = liveTranscription; liveTranscription = nil
        let draining = finalizingTranscription
        let job = pipelineTask, previous = sleepTask
        isPreparingForSleep = true
        let generation = UUID(); sleepGeneration = generation
        sleepTask = Task { [weak self] in
            await previous?.value
            await live?.finish(cancel: true)
            await draining?.finish(cancel: true)
            await job?.value
            while self?.isFinalizingRecording == true { try? await Task.sleep(for: .milliseconds(20)) }
            await LocalTranscription.engine.unload()
            guard let self, self.sleepGeneration == generation else { return }
            self.isPreparingForSleep = false
        }
    }

    @discardableResult func systemDidWake() -> Task<Void, Never> {
        isSleeping = false
        let preparation = sleepTask, generation = sleepGeneration
        return Task { [weak self] in
            await preparation?.value
            guard let self, !self.isSleeping, !self.isTerminating, self.sleepGeneration == generation else { return }
            let ids = self.wakeResumeIDs; self.wakeResumeIDs = []
            for id in ids {
                guard let item = self.recordings.first(where: { $0.id == id }), item.work?.cause == .sleep,
                      self.canResumeWork(id) else { continue }
                self.enqueue(id, lectureOnly: item.work?.kind == .summary)
            }
        }
    }

    func toggleRecordingPause() {
        guard !isSleeping, !isPreparingForSleep, let id = recordingID else { return }
        audio.pauseRecording()
        guard recordingID == id else { return } // the recorder may report an input failure
        update(id) {
            $0.duration = self.audio.recordingTime
            $0.work = .init(kind: .recording, state: .running)
            $0.message = nil
        }
        if !audio.isPausedRecording, liveTranscription == nil, settings.transcriptionReady,
           let item = recordings.first(where: { $0.id == id }), !item.recordsAudioOnly, let repository {
            do {
                let live = LocalRecordingTranscription(audio: try repository.audioURL(for: item),
                    directory: try repository.directory(for: item), configuration: settings.transcriptionConfiguration)
                live.onIssue = { [weak self] message in self?.update(id) { $0.message = message } }
                liveTranscription = live; live.start()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func canResumeWork(_ id: UUID) -> Bool {
        guard canModify(id), let item = recordings.first(where: { $0.id == id }), item.work?.state == .interrupted else { return false }
        if item.work?.kind == .recording && (item.audioFileName == nil || item.duration <= 0) { return false }
        return settings.analysisEnabled && (item.work?.kind == .summary || settings.transcriptionReady)
    }

    func resumeWork(_ id: UUID) {
        guard let item = recordings.first(where: { $0.id == id }), canResumeWork(id) else { return }
        enqueue(id, lectureOnly: item.work?.kind == .summary)
    }

    /// Repairs only app-owned interrupted recordings. No microphone or AI runs.
    func recoverRecordings() async {
        let ids = recordings.filter {
            $0.work?.kind == .recording && $0.work?.state == .interrupted && ($0.audioFileName == nil || $0.duration <= 0)
        }.map(\.id)
        for id in ids {
            guard !isTerminating, id != recordingID, id != processingID, !recoveringIDs.contains(id),
                  let item = recordings.first(where: { $0.id == id }), let repository else { continue }
            recoveringIDs.insert(id)
            defer { recoveringIDs.remove(id) }
            do {
                let directory = try repository.directory(for: item)
                var url = try repository.audioURL(for: item)
                if item.audioFileName == nil {
                    // Also handles old recordings that crashed before the ASR marker existed.
                    try LocalTranscription.prepareRecording(directory: directory)
                    if let repaired = try await LocalTranscription.recoverInterrupted(audio: url, directory: directory, language: settings.language) { url = repaired }
                }
                let source = url
                let info = try await Task.detached { try AudioEngine.inspect(source) }.value
                guard update(id, {
                    $0.audioFileName = source.lastPathComponent; $0.duration = info.duration; $0.waveform = info.waveform
                    if $0.recordsAudioOnly && $0.segments.isEmpty {
                        $0.status = .saved; $0.work = nil
                        $0.message = "녹음이 중단되기 전까지 저장된 음성을 복구했습니다."
                    } else { $0.status = $0.segments.isEmpty ? .queued : $0.completedStatus }
                }) else { continue }
                if selectedID == id { try audio.load(source) }
            } catch {
                update(id) { $0.message = "저장된 음성을 확인하지 못했습니다. 원본은 그대로 보관했습니다. 저장 공간과 파일을 확인해 주세요." }
            }
        }
    }
    @discardableResult func update(_ id: UUID, _ change: (inout Recording) -> Void) -> Bool {
        guard let index = recordings.firstIndex(where: { $0.id == id }), let repository else { return false }
        var copy = recordings[index]; change(&copy)
        // Keep the user's newest edits in memory when storage fails, and retry them before quitting.
        recordings[index] = copy
        do { try repository.save(copy); unsavedIDs.remove(id); return true }
        catch { unsavedIDs.insert(id); errorMessage = "변경 사항을 디스크에 저장하지 못했습니다. 앱을 닫기 전에 저장 공간과 폴더 권한을 확인해 주세요.\n\(error.localizedDescription)"; return false }
    }

    @discardableResult func retryUnsavedChanges() -> Bool {
        for id in Array(unsavedIDs) { update(id) { _ in } }
        return unsavedIDs.isEmpty
    }

    /// Return false to keep the app open when the latest metadata could not be saved.
    func prepareForTermination() async -> Bool {
        isTerminating = true
        settings.cancelSpeechPreparation()
        await sleepTask?.value
        for id in [processingID].compactMap({ $0 }) + queue {
            update(id) { $0.work?.interrupt(.appClosed) }
        }
        pipelineTask?.cancel(); importRunner?.cancel()
        for id in queue { update(id) { $0.status = $0.segments.isEmpty ? .queued : $0.completedStatus; $0.message = nil } }
        queue.removeAll()
        lectureOnlyIDs.removeAll()
        await stopRecording(enqueueForTranscription: false)
        await pipelineTask?.value
        while isImporting || isFinalizingRecording || isAddingDemo { try? await Task.sleep(for: .milliseconds(50)) }
        let saved = retryUnsavedChanges()
        if !saved { isTerminating = false }
        else { settings.cancelAIConnectionCheck(); await LocalTranscription.engine.unload() }
        return saved
    }
    @discardableResult func move(_ recording: Recording, to project: Project) -> Bool {
        guard canModify(recording.id), recording.projectID != project.id else { return false }
        do {
            guard let repository else { return false }
            let moved = try repository.move(recording, to: project)
            if let index = recordings.firstIndex(where: { $0.id == recording.id }) { recordings[index] = moved }
            unsavedIDs.remove(recording.id)
            if selectedID == recording.id { selectedProjectID = project.id; search = "" }
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func moveRecordings(_ references: [RecordingTransfer], to project: Project) -> Bool {
        guard !references.isEmpty, projects.contains(where: { $0.id == project.id }),
              Set(references.map(\.recordingID)).count == references.count else { return false }
        let items = references.compactMap { reference in
            recordings.first { $0.id == reference.recordingID && $0.projectID == reference.projectID }
        }
        guard items.count == references.count,
              items.allSatisfy({ canModify($0.id) && $0.projectID != project.id }) else { return false }
        var moved = false
        for item in items {
            guard move(item, to: project) else { return moved }
            moved = true
        }
        notify("녹음을 \(project.name) 폴더로 옮겼습니다")
        return moved
    }
    func trash(_ recording: Recording) {
        guard canModify(recording.id) else { return }
        do {
            guard let repository else { return }
            try repository.trash(recording); recordings.removeAll { $0.id == recording.id }; unsavedIDs.remove(recording.id)
            if selectedID == recording.id { select(visibleRecordings.first?.id) }
            notify("휴지통으로 이동했습니다")
        } catch { errorMessage = error.localizedDescription }
    }
    func export(_ recording: Recording, format: String) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = LibraryRepository.safeName(recording.title) + "." + format
        panel.allowedContentTypes = [UTType(filenameExtension: format) ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data: Data
            if format == "srt" { data = Data(Transcript.srt(recording.segments).utf8) }
            else if format == "json" { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601; data = try encoder.encode(recording) }
            else { data = Data(recording.fullText.utf8) }
            try data.write(to: url, options: .atomic); notify("내보내기를 완료했습니다")
        } catch { errorMessage = error.localizedDescription }
    }
    func copyTranscript() {
        guard let selected else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(selected.segments.map { showOriginal ? $0.originalText : $0.text }.joined(separator: "\n"), forType: .string)
        notify("전사문을 복사했습니다")
    }
    func notify(_ message: String) {
        toastTask?.cancel(); toast = message
        toastTask = Task { try? await Task.sleep(for: .seconds(3)); if !Task.isCancelled { self.toast = nil } }
    }
    func addDemo() async {
        guard !isAddingDemo, !isTerminating else { return }
        if let existing = recordings.first(where: \.isDemo) { search = ""; select(existing.id); return }
        guard let repository else { return }
        isAddingDemo = true; defer { isAddingDemo = false }
        do {
            let resources = AppResources.directory
            let source = resources.appendingPathComponent("welcome.wav")
            let transcript = resources.appendingPathComponent("welcome.json")
            guard let project = projects.first else { return }
            let info = try await Task.detached { try AudioEngine.inspect(source) }.value
            guard !isTerminating, !isSleeping, !isPreparingForSleep else { return }
            let originalSegments = try Transcript.parseLegacyTranscript(Data(contentsOf: transcript), duration: info.duration)
            var item = try repository.createRecording(project: project, title: "둥둥이, 처음 만나는 순간")
            try FileManager.default.copyItem(at: source, to: repository.audioURL(for: item))
            item.duration = info.duration; item.waveform = info.waveform; item.isDemo = true; item.status = .ready
            item.segments = originalSegments
            let corrections = resources.appendingPathComponent("welcome-corrections.json")
            if FileManager.default.fileExists(atPath: corrections.path) {
                item.segments = try Transcript.applyCorrections(Data(contentsOf: corrections), to: item.segments)
            }
            item.notes = "둥둥이의 기능을 둘러보기 위한 합성 음성 샘플입니다.\n\n문장을 클릭하면 해당 위치부터 들을 수 있습니다. 필기는 클릭해서 바로 수정할 수 있습니다."
            try repository.save(item); recordings.insert(item, at: 0)
            search = ""; select(item.id)
        } catch { errorMessage = error.localizedDescription }
    }
}
