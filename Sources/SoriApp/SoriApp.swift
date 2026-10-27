import SwiftUI
import AppKit
import Observation

@main
struct BungBungiApp {
    static var runsWithoutUI: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--snapshot") || arguments.contains("--integration-report")
    }
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Automated checks render offscreen and must never interrupt the user's current app.
        app.setActivationPolicy(runsWithoutUI ? .prohibited : .regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

/// AppKit owns the single document window; SwiftUI owns all of its content.
/// Explicit ownership also makes command-line launches and relocated .app bundles reliable.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    let store = AppStore(settings: SettingsPreview.makeSettings())
    private var window: NSWindow?
    private var settingsWindow: NSWindow?
    private var terminationRequested = false
    private var snapshotView: NSView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = ProcessInfo.processInfo.arguments
        // No menu, hosting view, or window is needed to exercise the pipeline.
        if let index = args.firstIndex(of: "--integration-report"), args.count > index + 1 {
            let report = URL(fileURLWithPath: args[index + 1])
            Task { exit(await IntegrationCheck.run(store: store, reportURL: report) ? 0 : 1) }
            return
        }
        // Render into memory without creating or ordering an NSWindow.
        if let index = args.firstIndex(of: "--snapshot"), args.count > index + 1 {
            captureOffscreen(args: args, path: args[index + 1])
            return
        }
        store.settings.refreshAIConnection()
        store.settings.refreshSpeechAvailability()
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(systemWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        Task { await store.recoverRecordings() }
        buildMenu()
        let minimum = args.contains("--minimum-window")
        let frame = NSRect(x: 0, y: 0, width: minimum ? 1000 : 1280, height: minimum ? 670 : 820)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "둥둥이"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 1000, height: 670)
        window.backgroundColor = NSColor(SoriTheme.paper)
        window.appearance = NSAppearance(named: .aqua)
        window.delegate = self
        window.contentView = NSHostingView(rootView: ContentView(store: store)
            .frame(minWidth: 1000, minHeight: 670)
            .ignoresSafeArea(.container, edges: .top)
            .preferredColorScheme(.light).tint(SoriTheme.accent))
        window.center()
        if !args.contains("--snapshot") { window.setFrameAutosaveName("BungBungiMainWindow") }
        self.window = window
        observeSettings()
        NotificationCenter.default.addObserver(self, selector: #selector(showSettingsNotification(_:)), name: Notification.Name("BungBungiShowSettings"), object: nil)
        if !args.contains("--background") {
            if NSApp.isActive { window.makeKeyAndOrderFront(nil) }
            else { window.orderBack(nil) }
        }

        if args.contains("--notes-preview") { store.showNotes = true }
        if args.contains("--focus-preview") { store.focusMode = true }
        if args.contains("--settings-preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.store.showSettings = true }
        }

    }

    private func captureOffscreen(args: [String], path: String) {
        if args.contains("--settings-preview") || args.contains("--providers-preview") { store.settings.refreshAIConnection() }
        if args.contains("--notes-preview") { store.showNotes = true }
        if args.contains("--focus-preview") { store.focusMode = true }
        // Give the bundled demo time to load, then construct the view from its final state.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            // Mutate only the temporary fixture; never run recognition or AI requests.
            if args.contains("--processing-preview") || args.contains("--polishing-preview") || args.contains("--summary-preview") || args.contains("--queued-preview"),
               let id = self.store.selectedID,
               let index = self.store.recordings.firstIndex(where: { $0.id == id }) {
                self.store.recordings[index].status = args.contains("--polishing-preview") || args.contains("--summary-preview") ? .polishing : .transcribing
                self.store.recordings[index].lectureHighlights = nil
                if !args.contains("--transcript-preview") { self.store.recordings[index].segments = [] }
                self.store.processingID = id
                self.store.processingStartedAt = Date().addingTimeInterval(args.contains("--polishing-preview") ? -323 : -83)
                self.store.updateProgress(.init(stage: args.contains("--polishing-preview") ? .correction : .transcription,
                    detail: args.contains("--polishing-preview") ? "강의 전체의 맥락을 살펴 인식 오류와 띄어쓰기를 다듬습니다." : "저장된 음성을 텍스트로 옮깁니다. 이미 처리한 구간은 이어서 사용해요.",
                    completed: args.contains("--polishing-preview") ? nil : 2460, total: args.contains("--polishing-preview") ? nil : 4500,
                    unit: args.contains("--polishing-preview") ? .sentences : .audio,
                    estimatedDuration: args.contains("--polishing-preview") ? 300 : nil), for: id)
                if args.contains("--polishing-preview") {
                    self.store.processingCompletedSteps = [.transcription]
                    self.store.processingEstimateStartedUptime = ProcessInfo.processInfo.systemUptime - (args.contains("--overrun-preview") ? 420 : 180)
                }
                if args.contains("--download-preview") {
                    self.store.updateProgress(.init(stage: .speechPreparation,
                        detail: "처음 사용하는 언어 모델을 다운로드합니다. 녹음은 보관되어 있습니다.",
                        completed: 0.42, total: 1, unit: .download), for: id)
                }
                if args.contains("--summary-preview") {
                    self.store.processingSummaryOnly = args.contains("--summary-only-preview")
                    self.store.processingCompletedSteps = self.store.processingSummaryOnly ? [] : [.transcription, .correction]
                    self.store.updateProgress(.init(stage: .analysis, detail: "교수가 강조한 내용과 시험 안내를 원문에서 확인합니다."), for: id)
                    if self.store.processingSummaryOnly { self.store.processingCompletedSteps = [] }
                }
                if args.contains("--queued-preview") {
                    self.store.queue = [id]
                    self.store.recordings[index].status = .queued
                    self.store.recordings[index].work = .init(kind: .transcription)
                    self.store.processingID = UUID()
                    self.store.processingSummaryOnly = true
                    self.store.processingCompletedSteps = [.transcription, .correction]
                }
            }
            if args.contains("--interrupted-preview") || args.contains("--sleep-preview"),
               let id = self.store.selectedID, let index = self.store.recordings.firstIndex(where: { $0.id == id }) {
                let sleeping = args.contains("--sleep-preview")
                self.store.recordings[index].segments = []
                self.store.recordings[index].lectureHighlights = nil
                self.store.recordings[index].work = .init(kind: sleeping ? .recording : .transcription,
                    state: .interrupted, cause: sleeping ? .sleep : .unexpected, step: sleeping ? nil : .correction)
                self.store.recordings[index].status = sleeping ? .recording : .queued
                if sleeping {
                    self.store.recordingID = id
                    self.store.audio.isRecording = true
                    self.store.audio.isPausedRecording = true
                    self.store.audio.recordingTime = 2460
                }
            }
            if args.contains("--review-preview"), let id = self.store.selectedID,
               let index = self.store.recordings.firstIndex(where: { $0.id == id }) {
                self.store.recordings[index].status = .reviewNeeded
                self.store.recordings[index].reviewRanges = [.init(start: 10, end: 12)]
                self.store.recordings[index].message = "일부 문장은 정확한 재생 위치를 확인하지 못해 대략적인 위치로 표시했습니다."
                if !self.store.recordings[index].segments.isEmpty {
                    self.store.recordings[index].segments[0].timingQuality = "approximate"
                }
            }
            SummaryPreview.configure(store: self.store, arguments: args)
            TranscriptPreview.configure(store: self.store, arguments: args)
            RecordingPreview.configure(store: self.store, arguments: args)
            let settings = args.contains("--settings-preview") || args.contains("--providers-preview")
            let search = args.contains("--search-preview") || args.contains("--empty-search-preview")
            if search { self.store.transcriptSearch = args.contains("--empty-search-preview") ? "일치하지 않는 검색어" : "녹음" }
            var size = settings ? (args.contains("--minimum-window") ? SettingsView.minimumSize : SettingsView.defaultSize) : NSSize(width: args.contains("--minimum-window") ? 1000 : 1280, height: args.contains("--minimum-window") ? 670 : 820)
            if settings { self.store.settingsSection = args.contains("--providers-preview") ? .providers : (args.contains("--shortcuts-preview") ? .shortcuts : .speech) }
            var content = settings ? AnyView(SettingsView(store: self.store, providerDetailsExpanded: args.contains("--provider-details-preview"))) : AnyView(ContentView(store: self.store, transcriptVisible: args.contains("--transcript-preview"), searchVisible: search))
            if args.contains("--recording-help-preview") {
                size = NSSize(width: 330, height: 350)
                content = AnyView(RecordingModeHelpContent().frame(maxHeight: .infinity).background(SoriTheme.paper))
            }
            let view = NSHostingView(rootView: content.frame(width: size.width, height: size.height).environment(\.displayScale, 2).preferredColorScheme(.light).tint(SoriTheme.accent))
            view.appearance = NSAppearance(named: .aqua)
            view.frame = NSRect(origin: .zero, size: size)
            self.snapshotView = view
            view.layoutSubtreeIfNeeded()
            TranscriptPreview.scrollAway(in: view, arguments: args)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                view.layoutSubtreeIfNeeded()
                guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
                bitmap.size = size
                view.cacheDisplay(in: view.bounds, to: bitmap)
                do {
                    guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
                    try data.write(to: URL(fileURLWithPath: path))
                    print("Offscreen snapshot: windows=\(NSApp.windows.count), visible=\(NSApp.windows.filter(\.isVisible).count), active=\(NSApp.isActive), policy=\(NSApp.activationPolicy().rawValue)")
                    for window in NSApp.windows { print("Internal window: \(type(of: window)), visible=\(window.isVisible)") }
                    exit(0)
                } catch { exit(1) }
            }
        }
    }

    private func buildMenu() {
        let menu = NSMenu()
        let app = NSMenu()
        add("둥둥이에 관하여", to: app, action: #selector(about))
        app.addItem(.separator())
        add("설정…", to: app, action: #selector(settings), key: ",")
        app.addItem(.separator())
        add("둥둥이 가리기", to: app, action: #selector(NSApplication.hide(_:)), key: "h", target: NSApp)
        add("모두 보기", to: app, action: #selector(NSApplication.unhideAllApplications(_:)), target: NSApp)
        app.addItem(.separator())
        add("둥둥이 종료", to: app, action: #selector(NSApplication.terminate(_:)), key: "q", target: NSApp)
        attach(app, title: "둥둥이", to: menu)

        let file = NSMenu(title: "파일")
        add("강의 기록하기", to: file, action: #selector(record), key: "r")
        add("녹음하기", to: file, action: #selector(recordAudioOnly), key: "r", modifiers: [.command, .option])
        add("녹음 일시 정지", to: file, action: #selector(pauseRecording), key: "r", modifiers: [.command, .shift])
        add("오디오 가져오기…", to: file, action: #selector(importAudio), key: "o")
        file.addItem(.separator())
        add("창 닫기", to: file, action: #selector(closeWindow), key: "w")
        attach(file, title: "파일", to: menu)

        let edit = NSMenu(title: "편집")
        for (title, selector, key) in [("실행 취소", "undo:", "z"), ("오려두기", "cut:", "x"), ("복사", "copy:", "c"), ("붙여넣기", "paste:", "v"), ("전체 선택", "selectAll:", "a")] {
            let item = NSMenuItem(title: title, action: Selector(selector), keyEquivalent: key)
            edit.addItem(item)
        }
        edit.addItem(.separator())
        add("전사문에서 찾기", to: edit, action: #selector(findTranscript), key: "f")
        add("보관함에서 찾기", to: edit, action: #selector(findLibrary), key: "f", modifiers: [.command, .shift])
        attach(edit, title: "편집", to: menu)

        let playback = NSMenu(title: "재생")
        add("재생 / 일시 정지", to: playback, action: #selector(playPause), key: "p", modifiers: [.command, .shift])
        add("10초 뒤로", to: playback, action: #selector(backward), key: String(UnicodeScalar(NSLeftArrowFunctionKey)!), modifiers: .command)
        add("10초 앞으로", to: playback, action: #selector(forward), key: String(UnicodeScalar(NSRightArrowFunctionKey)!), modifiers: .command)
        playback.addItem(.separator())
        add("북마크 추가", to: playback, action: #selector(bookmark), key: "b")
        add("집중 모드", to: playback, action: #selector(focus), key: "l", modifiers: [.command, .shift])
        attach(playback, title: "재생", to: menu)

        let help = NSMenu(title: "도움말")
        add("샘플 녹음으로 둘러보기", to: help, action: #selector(demo))
        attach(help, title: "도움말", to: menu)
        NSApp.mainMenu = menu
    }
    private func attach(_ submenu: NSMenu, title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu; menu.addItem(item)
    }
    private func add(_ title: String, to menu: NSMenu, action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers; item.target = target ?? self; menu.addItem(item)
    }
    @objc private func about() { NSApp.orderFrontStandardAboutPanel(nil) }
    @objc private func settings() { store.showSettings = true; presentSettings() }
    @objc private func showSettingsNotification(_ notification: Notification) {
        if let value = notification.userInfo?["section"] as? String, let section = SettingsSection(rawValue: value) {
            store.settingsSection = section
        }
        settings()
    }
    @objc private func record() {
        if store.audio.isRecording { Task { await store.stopRecording() } }
        else { store.requestRecording() }
    }
    @objc private func recordAudioOnly() { store.requestRecording(mode: .audioOnly) }
    @objc private func pauseRecording() { store.toggleRecordingPause() }
    @objc private func systemWillSleep() { store.systemWillSleep() }
    @objc private func systemDidWake() {
        let resumed = store.systemDidWake()
        Task { await resumed.value; await store.recoverRecordings() }
    }
    @objc private func importAudio() { store.importAudio() }
    @objc private func closeWindow() { NSApp.keyWindow?.performClose(nil) }
    @objc private func playPause() { store.audio.togglePlayback() }
    @objc private func backward() { store.audio.seek(store.audio.currentTime - 10) }
    @objc private func forward() { store.audio.seek(store.audio.currentTime + 10) }
    @objc private func bookmark() { store.bookmark() }
    @objc private func focus() { store.focusMode.toggle() }
    @objc private func demo() { Task { await store.addDemo() } }
    @objc private func findTranscript() { NotificationCenter.default.post(name: Notification.Name("BungBungiFindTranscript"), object: nil) }
    @objc private func findLibrary() {
        store.focusMode = false
        DispatchQueue.main.async { NotificationCenter.default.post(name: Notification.Name("BungBungiFindLibrary"), object: nil) }
    }

    private func observeSettings() {
        withObservationTracking { _ = store.showSettings; _ = store.isInstalling } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.store.showSettings {
                    if self.settingsWindow?.isVisible != true { self.presentSettings() }
                } else { self.settingsWindow?.orderOut(nil) }
                self.settingsWindow?.standardWindowButton(.closeButton)?.isEnabled = !self.store.isInstalling
                self.observeSettings()
            }
        }
    }

    private func presentSettings() {
        if settingsWindow == nil {
            let settings = NSWindow(contentRect: NSRect(origin: .zero, size: SettingsView.defaultSize), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            settings.contentMinSize = SettingsView.minimumSize
            settings.title = "둥둥이 설정"
            settings.isReleasedWhenClosed = false
            settings.delegate = self
            settings.backgroundColor = NSColor(SoriTheme.paper)
            settings.appearance = NSAppearance(named: .aqua)
            settings.contentView = NSHostingView(rootView: SettingsView(store: store).preferredColorScheme(.light).tint(SoriTheme.accent))
            settings.center()
            settingsWindow = settings
        }
        if !BungBungiApp.runsWithoutUI { settingsWindow?.makeKeyAndOrderFront(nil) }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard !terminationRequested else { return false }
        switch menuItem.action {
        case #selector(record):
            menuItem.title = store.audio.isRecording ? "녹음 마치기" : "강의 기록하기"
            return store.repository != nil && !store.isStartingRecording && !store.isFinalizingRecording
        case #selector(recordAudioOnly):
            return store.repository != nil && !store.audio.isRecording && !store.isStartingRecording && !store.isFinalizingRecording
        case #selector(pauseRecording):
            menuItem.title = store.audio.isPausedRecording ? "녹음 재개" : "녹음 일시 정지"
            return store.audio.isRecording
        case #selector(importAudio): return store.repository != nil && !store.isImporting
        case #selector(playPause), #selector(backward), #selector(forward), #selector(bookmark):
            return store.selected != nil && store.audio.duration > 0 && !store.audio.isRecording
        case #selector(findTranscript): return !(store.selected?.segments.isEmpty ?? true)
        case #selector(focus):
            menuItem.state = store.focusMode ? .on : .off
            return store.selected != nil
        default: return true
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !BungBungiApp.runsWithoutUI else { return false }
        window?.makeKeyAndOrderFront(nil); return true
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        guard !BungBungiApp.runsWithoutUI, NSApp.keyWindow == nil else { return }
        window?.makeKeyAndOrderFront(nil)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === settingsWindow {
            guard !store.isInstalling else { return false }
            store.showSettings = false; return true
        }
        NSApp.terminate(nil); return false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationRequested else { return .terminateCancel }
        if store.busy {
            let alert = NSAlert()
            alert.messageText = store.audio.isRecording ? "녹음을 저장하고 종료할까요?" : "진행 중인 작업을 멈추고 종료할까요?"
            alert.informativeText = store.audio.isRecording
                ? "지금까지 녹음한 오디오를 저장합니다. 다음에 앱을 열어 전사할 수 있습니다."
                : "저장된 오디오와 전사문은 보관됩니다. 완료되지 않은 전사는 다시 시작할 수 있습니다."
            alert.addButton(withTitle: store.audio.isRecording ? "저장 후 종료" : "중지 후 종료")
            alert.addButton(withTitle: "계속 작업")
            alert.buttons.last?.keyEquivalent = "\u{1b}"
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        terminationRequested = true
        // Debounced notes must be flushed even when the app is otherwise idle.
        NotificationCenter.default.post(name: Notification.Name("BungBungiWillSave"), object: nil)
        Task {
            let saved = await store.prepareForTermination()
            while store.isInstalling { try? await Task.sleep(for: .milliseconds(50)) }
            if !saved {
                terminationRequested = false
                if !BungBungiApp.runsWithoutUI { window?.makeKeyAndOrderFront(nil) }
            }
            sender.reply(toApplicationShouldTerminate: saved)
        }
        return .terminateLater
    }
}
